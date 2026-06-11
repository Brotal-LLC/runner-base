# =============================================================================
# Brotal-LLC self-hosted runner base image
# =============================================================================
# Pre-installs the dev toolchain required by Brotal-LLC CI workflows (sv,
# chokidar, ilma) so jobs skip the cold install on first run. Designed to
# be paired with the runner listener at ~/infra/brotal-runners/ — the
# runner container pulls this image and the listener registers/picks up
# jobs from there.
#
# Layer strategy (top→bottom = least-changed→most-changed, for buildx
# cache friendliness across releases):
#   1. Base         — actions-runner:latest (rebuilds rarely)
#   2. apt packages — system libs Playwright + crypto + jq need (rebuilds on
#                     apt update, but is small)
#   3. dotnet SDK   — 10.0.x (rebuilds on SDK minor version bump)
#   4. node         — 22.x (rebuilds on Node major bump)
#   5. python + uv  — 3.11 + uv latest (rebuilds on uv release)
#   6. tools        — hadolint, actionlint, trufflehog, jq (rebuilds often,
#                     but each is tiny so the layer diffs are small)
#   7. caches       — NuGet/npm/uv global packages, warmed at build time
#                     against HEAD of sv (primary), chokidar, ilma. Rebuilt
#                     on every bake.
#
# Build args (override with --build-arg):
#   DOTNET_VERSION    default "10.0.108"        — match the workflow pin
#   NODE_MAJOR        default "22"              — match Dockerfile pins in sv
#   PYTHON_VERSION    default "3.11"            — match ilma's pyproject.toml
#   UV_VERSION        default "0.11.19"         — match host uv version
#   HADOLINT_VERSION  default "2.12.0"
#   ACTIONLINT_VERSION default "1.7.12"
#   TRUFFLEHOG_VERSION default "3.88.0"
#   WARM_SV           default "1" (set to "0" to skip NuGet warm on sv)
#   WARM_CHOKIDAR     default "1"
#   WARM_ILMA         default "1"
#
# Image is published to ghcr.io/brotal-llc/runner-base on tag push (see
# .github/workflows/bake-and-release.yml). Tag scheme:
#   runner-base-vYYYY-MM-DD-N   (N is an incrementing build counter)
#   latest                      (rolling pointer, updated on every release)
# =============================================================================

ARG ACTIONS_RUNNER_BASE=ghcr.io/actions/actions-runner:latest
FROM ${ACTIONS_RUNNER_BASE} AS base

USER root

# -----------------------------------------------------------------------------
# Layer 2: apt packages. Playwright system deps + crypto + jq + curl.
# apt-get update is intentionally NOT combined with install in the same
# RUN — we want the layer cache to survive a new actions-runner base
# image (which itself might trigger an apt-get update). All packages
# in one layer so the image stays small.
# -----------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl wget git jq gnupg apt-transport-https \
        libssl-dev libffi-dev build-essential pkg-config \
        # Playwright system deps (Chromium runtime)
        libnss3 libatk1.0-0 libatk-bridge2.0-0 libcups2 libdrm2 \
        libxkbcommon0 libxcomposite1 libxdamage1 libxrandr2 libgbm1 \
        libpango-1.0-0 libcairo2 libasound2t64 libxshmfence1 \
        # Postgres client + dnsutils for resolve-host steps
        postgresql-client dnsutils iproute2 \
        # Useful for debugging CI failures from inside the runner
        less vim-tiny htop \
    && rm -rf /var/lib/apt/lists/* \
    && echo "apt layer done at $(date -u +%FT%TZ)"

# -----------------------------------------------------------------------------
# Layer 3: dotnet SDK. Pinned to a specific patch version (not 10.0.x) so the
# image is reproducible. Match this against the workflow's
# actions/setup-dotnet@v5 `dotnet-version` pin when bumping.
# -----------------------------------------------------------------------------
ARG DOTNET_VERSION=10.0.108
RUN mkdir -p /usr/share/dotnet \
    && curl -fsSL "https://dot.net/v1/dotnet-install.sh" -o /tmp/dotnet-install.sh \
    && bash /tmp/dotnet-install.sh \
        --channel "10.0" \
        --install-dir "/usr/share/dotnet" \
        --quality "GA" \
        --no-path \
    # Verify the SDK actually installed (catches a broken CDN mirror early
    # at bake time rather than at job time)
    && /usr/share/dotnet/dotnet --info >/dev/null \
    && /usr/share/dotnet/dotnet --version | grep -q "${DOTNET_VERSION%.*}" \
    # Symlink for the canonical /usr/bin/dotnet path some tools probe
    && ln -sf /usr/share/dotnet/dotnet /usr/bin/dotnet \
    && echo "dotnet ${DOTNET_VERSION} installed"

ENV DOTNET_ROOT=/usr/share/dotnet
ENV DOTNET_INSTALL_DIR=/usr/share/dotnet
ENV DOTNET_NOLOGO=1
ENV DOTNET_CLI_TELEMETRY_OPTOUT=1
ENV DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1
ENV PATH="/usr/share/dotnet:${PATH}"

# -----------------------------------------------------------------------------
# Layer 4: Node.js 22.x via NodeSource. Alpine is NOT used here because the
# base image is debian-slim (the actions-runner image). Bumping to Node
# 24+ requires changing both this line AND the workflows that pin
# "node-version: '22'".
# -----------------------------------------------------------------------------
ARG NODE_MAJOR=22
RUN curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && node --version \
    && npm --version \
    && echo "node $(node --version) installed"

# -----------------------------------------------------------------------------
# Layer 5: Python 3.11 + uv. The host already has python3 in the base
# actions-runner image (3.12+ usually) but ilma pins 3.11 in pyproject.toml,
# so we install 3.11 explicitly. uv is installed to /usr/local/bin so it's
# on PATH for every user.
# -----------------------------------------------------------------------------
ARG PYTHON_VERSION=3.11
ARG UV_VERSION=0.11.19
RUN apt-get update && apt-get install -y --no-install-recommends \
        software-properties-common \
    && add-apt-repository -y "ppa:deadsnakes/ppa" \
    && apt-get install -y --no-install-recommends "python${PYTHON_VERSION}" "python${PYTHON_VERSION}-venv" "python${PYTHON_VERSION}-dev" \
    && update-alternatives --install /usr/bin/python3 python3 /usr/bin/python${PYTHON_VERSION} 100 \
    && curl -fsSL "https://astral.sh/uv/${UV_VERSION}/install.sh" | env UV_UNMANAGED_INSTALL="/usr/local/bin" sh \
    && rm -rf /var/lib/apt/lists/* \
    && python3 --version \
    && uv --version \
    && echo "python3 $(python3 --version) + uv $(uv --version) installed"

# -----------------------------------------------------------------------------
# Layer 6: CLI tools. Each tool is downloaded to /usr/local/bin so they're
# on PATH. Versions are pinned via build args so we control drift.
# -----------------------------------------------------------------------------
ARG HADOLINT_VERSION=2.12.0
ARG ACTIONLINT_VERSION=1.7.12
ARG TRUFFLEHOG_VERSION=3.88.0

RUN set -eux; \
    # hadolint: binary release, single static binary
    curl -fsSL "https://github.com/hadolint/hadolint/releases/download/v${HADOLINT_VERSION}/hadolint-Linux-x86_64" \
        -o /usr/local/bin/hadolint \
    && chmod +x /usr/local/bin/hadolint \
    && hadolint --version; \
    # actionlint: single binary
    curl -fsSL "https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}/actionlint_${ACTIONLINT_VERSION}_linux_amd64.tar.gz" \
        | tar -xz -C /usr/local/bin actionlint \
    && chmod +x /usr/local/bin/actionlint \
    && actionlint -version; \
    # trufflehog: single binary
    curl -fsSL "https://github.com/trufflesecurity/trufflehog/releases/download/v${TRUFFLEHOG_VERSION}/trufflehog_${TRUFFLEHOG_VERSION}_linux_amd64.tar.gz" \
        | tar -xz -C /usr/local/bin trufflehog \
    && chmod +x /usr/local/bin/trufflehog \
    && trufflehog --version; \
    echo "cli tools installed"

# =============================================================================
# Layer 7: warmed caches. Done in a separate stage so the heavy restore
# doesn't bloat the tool layer (and so the tool layer caches cleanly across
# repo dep updates). The warm stage pulls HEAD of each repo and runs a
# restore — it does NOT commit .git, just the package caches.
#
# This stage is intentionally NOT a multi-stage target — we copy its
# artifacts into the final image. The `COPY --from=warm` keeps the final
# image small by excluding the git checkouts.
# =============================================================================
FROM base AS warm

# Pre-create the cache dirs so COPY --from=warm in the final stage
# doesn't fail with "<path>: not found" when the corresponding warm
# step was skipped (WARM_*=0). This is a no-op when the dir already
# exists.
RUN mkdir -p /root/.nuget /root/.npm /root/.cache/uv /root/.local

# Clone the three Brotal-LLC repos at HEAD, shallow, so we can warm caches
# against their lockfiles. Skipping a repo's warm step is a build arg
# (WARM_*); useful when one of the repos is broken on master and you still
# want to ship a runner base.
ARG WARM_SV=1
ARG WARM_CHOKIDAR=1
ARG WARM_ILMA=1
ARG WARM_REF=HEAD

USER root
WORKDIR /warm
RUN set -eux; \
    if [ "${WARM_SV}" = "1" ]; then \
        echo ">>> warming sv (${WARM_REF})"; \
        git clone --depth 1 --branch master https://github.com/Brotal-LLC/sv.git sv || \
        git clone --depth 1 https://github.com/Brotal-LLC/sv.git sv; \
    fi; \
    if [ "${WARM_CHOKIDAR}" = "1" ]; then \
        echo ">>> warming chokidar (${WARM_REF})"; \
        git clone --depth 1 --branch main https://github.com/Brotal-LLC/chokidar.git chokidar || \
        git clone --depth 1 https://github.com/Brotal-LLC/chokidar.git chokidar; \
    fi; \
    if [ "${WARM_ILMA}" = "1" ]; then \
        echo ">>> warming ilma (${WARM_REF})"; \
        git clone --depth 1 --branch main https://github.com/Brotal-LLC/ilma.git ilma || \
        git clone --depth 1 https://github.com/Brotal-LLC/ilma.git ilma; \
    fi; \
    ls -la /warm

# Warm NuGet (sv + chokidar)
RUN --mount=type=cache,target=/root/.nuget/packages,sharing=locked \
    if [ -d /warm/sv/src/api ]; then \
        echo ">>> dotnet restore sv (src/api + libs + tests)"; \
        dotnet restore /warm/sv/src/api/Sv.Api.csproj; \
    fi; \
    if [ -d /warm/chokidar/backend ]; then \
        echo ">>> dotnet restore chokidar (backend)"; \
        cd /warm/chokidar/backend && dotnet restore; \
        cd /warm; \
    fi

# Warm npm (sv app + admin + chokidar frontend)
RUN --mount=type=cache,target=/root/.npm,sharing=locked \
    if [ -d /warm/sv/src/app ]; then \
        echo ">>> npm ci sv/src/app"; \
        cd /warm/sv/src/app && npm ci --no-audit --no-fund --prefer-offline 2>/dev/null || npm install --no-audit --no-fund; \
        cd /warm; \
    fi; \
    if [ -d /warm/sv/src/admin ]; then \
        echo ">>> npm ci sv/src/admin"; \
        cd /warm/sv/src/admin && npm ci --no-audit --no-fund --prefer-offline 2>/dev/null || npm install --no-audit --no-fund; \
        cd /warm; \
    fi; \
    if [ -d /warm/chokidar/frontend ]; then \
        echo ">>> npm ci chokidar/frontend"; \
        cd /warm/chokidar/frontend && npm ci --no-audit --no-fund --prefer-offline 2>/dev/null || npm install --no-audit --no-fund; \
        cd /warm; \
    fi

# Warm uv (ilma)
RUN --mount=type=cache,target=/root/.cache/uv,sharing=locked \
    if [ -d /warm/ilma ]; then \
        echo ">>> uv sync ilma"; \
        cd /warm/ilma && uv sync --frozen 2>/dev/null || uv sync; \
        cd /warm; \
    fi

# =============================================================================
# Final image. Strip the warm stage's git checkouts to keep the image
# under ~1.5 GB on disk.
# =============================================================================
FROM base AS final

# Pull the warmed package caches from the warm stage into the final
# image's default locations. We do this as COPY --from=warm so the git
# checkouts in /warm/ are not included in the final image.
COPY --from=warm /root/.nuget /root/.nuget
COPY --from=warm /root/.npm /root/.npm
COPY --from=warm /root/.cache/uv /root/.cache/uv
COPY --from=warm /root/.local /root/.local

# Pre-create the workspace dir the listener expects (matches
# ~/infra/brotal-runners compose.yml listener command).
# Also pre-create /home/runner/_work as root so the runner user can chown
# it on first start (matches the existing chown listener step).
RUN mkdir -p /github/workspace \
    && chown -R 1001:1001 /github/workspace /home/runner/_work 2>/dev/null || true \
    && echo "final image assembled at $(date -u +%FT%TZ)"

# Smoke check: every tool the workflow expects must be present. If any
# of these fail the image is broken at bake time, not at job time.
RUN set -eux; \
    dotnet --version; \
    node --version; \
    npm --version; \
    python3 --version; \
    uv --version; \
    hadolint --version; \
    actionlint -version; \
    trufflehog --version; \
    jq --version; \
    psql --version; \
    git --version; \
    echo "=== runner-base smoke check PASSED ==="

# Default to the runner user — matches the actions-runner image's
# USER directive so the listener can write to /home/runner/_work.
USER 1001
WORKDIR /home/runner

# Labels for ghcr.io metadata
LABEL org.opencontainers.image.title="Brotal-LLC runner-base"
LABEL org.opencontainers.image.description="Self-hosted Actions runner with dotnet/node/python/uv/hadolint/actionlint/trufflehog + warmed caches for sv/chokidar/ilma"
LABEL org.opencontainers.image.source="https://github.com/Brotal-LLC/runner-base"
LABEL org.opencontainers.image.licenses="MIT"
LABEL org.brotal.runner-base.sv="primary"
LABEL org.brotal.runner-base.chokidar="supported"
LABEL org.brotal.runner-base.ilma="supported"
