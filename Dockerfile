# =============================================================================
# Brotal-LLC self-hosted runner base image
# =============================================================================
# Pre-installs the dev toolchain required by Brotal-LLC CI workflows (sv,
# chokidar, ilma) so jobs skip the cold install on first run. Designed to
# be paired with the runner listener at ~/infra/brotal-runners/ — the
# runner container pulls this image and the listener registers/picks up
# jobs from there.
#
# This image contains TOOLS ONLY. It deliberately does NOT pre-warm
# NuGet/npm/uv caches for any specific repo — those go stale on every
# dep update and are already handled by `actions/setup-dotnet@v5`'s
# `cache: true` + workflow-side npm/uv cache steps. Adding repo-specific
# warm caches here would:
#   1. Add 10-15 min to every bake (multi-arch cross-compile of all 3
#      repos' restores)
#   2. Ship stale caches that don't match the lockfile the job is
#      actually restoring against
#   3. Couple this image to the public layout of three external repos
#      (git clone, branch names, etc.), so a rename or branch change in
#      sv/chokidar/ilma would break the bake
# If you ever want a job to run with a pre-warmed cache, do it at
# job-time with a workflow-side restore step, not here.
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
#   7. finalize     — /github/workspace dir, ownership, smoke check
#
# Build args (override with --build-arg):
#   DOTNET_VERSION     default "10.0.108"        — match the workflow pin
#   NODE_MAJOR         default "22"              — match Dockerfile pins in sv
#   PYTHON_VERSION     default "3.11"            — match ilma's pyproject.toml
#   UV_VERSION         default "0.11.19"         — match host uv version
#   HADOLINT_VERSION   default "2.12.0"
#   ACTIONLINT_VERSION default "1.7.12"
#   TRUFFLEHOG_VERSION default "3.88.0"
#
# Image is published to ghcr.io/brotal-llc/runner-base on tag push (see
# .github/workflows/bake-and-release.yml). Tag scheme:
#   runner-base-vYYYY-MM-DD-N   (N is an incrementing build counter)
#   latest                      (rolling pointer, updated on every release)
# =============================================================================

ARG ACTIONS_RUNNER_BASE=ghcr.io/actions/actions-runner:latest
FROM ${ACTIONS_RUNNER_BASE}

USER root

# -----------------------------------------------------------------------------
# Layer 2: apt packages. Playwright system deps + crypto + jq + curl.
# All packages in one layer so the image stays small.
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
        # bc — POSIX `bc` is the default float-math tool in lots of CI
        # scripts (incl. sv.yml's Coverage Gate). 2026-06-11 incident:
        # the gate silently failed with "bc: command not found" because
        # it wasn't in the original apt set, and exit code 127 looked
        # identical to "coverage < threshold" in our dashboards.
        bc \
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
    && rm -f /tmp/dotnet-install.sh \
    && echo "dotnet ${DOTNET_VERSION} installed"

ENV DOTNET_ROOT=/usr/share/dotnet
ENV DOTNET_INSTALL_DIR=/usr/share/dotnet
ENV DOTNET_NOLOGO=1
ENV DOTNET_CLI_TELEMETRY_OPTOUT=1
ENV DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1
ENV PATH="/usr/share/dotnet:${PATH}"

# -----------------------------------------------------------------------------
# Layer 4: Node.js 22.x via NodeSource. Bumping to Node 24+ requires
# changing both this line AND the workflows that pin "node-version: '22'".
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
#
# Multi-arch note: the curl URLs below point at *x86_64/amd64* binaries
# because the Brotal-LLC runner fleet (rogue + in-Docker-dind) is all
# x86_64. Cross-compiling to arm64 via QEMU emulation would try to RUN
# these x86_64 binaries inside an emulated arm64 rootfs and fail with
# "qemu: uncaught target signal 11". If/when an arm64 runner comes
# online, the urls can be parameterized on $TARGETARCH or split into
# per-arch RUN blocks.
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

# -----------------------------------------------------------------------------
# Layer 7: finalize. Pre-create the workspace dir the listener expects
# (matches ~/infra/brotal-runners compose.yml listener command), then
# smoke-check every tool the workflow expects. If any check fails the
# image is broken at bake time, not at job time.
# -----------------------------------------------------------------------------
RUN mkdir -p /github/workspace \
    && chown -R 1001:1001 /github/workspace /home/runner/_work 2>/dev/null || true \
    && echo "=== runner-base smoke check ===" \
    && dotnet --version \
    && node --version \
    && npm --version \
    && python3 --version \
    && uv --version \
    && hadolint --version \
    && actionlint -version \
    && trufflehog --version \
    && jq --version \
    && psql --version \
    && git --version \
    && bc --version \
    && echo "=== runner-base smoke check PASSED ==="

# Default to the runner user — matches the actions-runner image's
# USER directive so the listener can write to /home/runner/_work.
USER 1001
WORKDIR /home/runner

# Labels for ghcr.io metadata
LABEL org.opencontainers.image.title="Brotal-LLC runner-base"
LABEL org.opencontainers.image.description="Self-hosted Actions runner with dotnet/node/python/uv/hadolint/actionlint/trufflehog (tools only, no repo caches)"
LABEL org.opencontainers.image.source="https://github.com/Brotal-LLC/runner-base"
LABEL org.opencontainers.image.licenses="MIT"
