# Brotal-LLC runner-base

[![bake](https://github.com/Brotal-LLC/runner-base/actions/workflows/bake-and-release.yml/badge.svg)](https://github.com/Brotal-LLC/runner-base/actions/workflows/bake-and-release.yml)
[![image](https://img.shields.io/badge/ghcr.io-brotal--llc%2Frunner--base-blue)](https://github.com/Brotal-LLC/runner-base/pkgs/container/runner-base)

Self-hosted GitHub Actions runner base image with the full Brotal-LLC dev
toolchain pre-installed. **Tools only — no repo caches.** Workflow-side
caching (NuGet/npm/uv) is the consumer's responsibility.

**Latest published tag:** `2026-06-11-1`  (commit `3b1764c`)

## What it contains

- `dotnet` SDK 10.0.x
- `node` 22.x + `npm`
- `python` 3.11 + `uv`
- `hadolint`, `actionlint`, `trufflehog`, `jq`, `psql`
- Playwright system deps (Chromium runtime)

## Why no pre-warmed caches?

Pre-warming NuGet/npm/uv for sv/chokidar/ilma inside the image was tried
and rejected:

1. The `actions/setup-dotnet@v5` `cache: true` already caches NuGet across
   runs at the workflow level, so an image-baked cache is redundant.
2. Image-baked caches go stale the moment any of the three repos' lockfiles
   change — a 2-3 day freshness ceiling in practice.
3. The bake itself has to cross-compile 3 repos' restores for `linux/arm64`
   too, adding 10-15 min to every bake with no benefit when the caches
   aren't actually fresh.

If a specific workflow needs a pre-warmed cache, do it in a workflow-side
`actions/cache` step. The image stays neutral and simple.

## Usage in `~/infra/brotal-runners/`

Pin a specific tag in the `.env` file of each runner stack:

```env
# ~/infra/brotal-runners/inf-runner-1/.env
BROL_RUNNER_IMAGE=ghcr.io/brotal-llc/runner-base:2026-06-11-1
```

Then `docker compose up -d --force-recreate` in that stack. The runner
listener will pull the new image on recreate.

## Usage in CI workflows

On self-hosted runners, skip the cold `actions/setup-dotnet@v5` install
(it's the source of the network hangs we see with `dotnetcli.azureedge.net`):

```yaml
- name: Setup .NET
  uses: actions/setup-dotnet@v5
  if: runner.name != 'inframework-runner-1' && runner.name != 'inframework-runner-2' && runner.name != 'inframework-runner-3'
  with:
    dotnet-version: '10.0.x'
```

Same pattern for `setup-node`, `setup-python`, `setup-uv`. Replace
`uses: docker://hadolint/hadolint` and `uses: docker://rhysd/actionlint`
and `docker run trufflesecurity/trufflehog` with direct `run: hadolint ...`
etc. — the binaries are on `/usr/local/bin` in the image.

## Tag scheme

- `runner-base-vYYYY-MM-DD-N` — pinned release tags
- `latest` — rolling pointer to the most recent successful bake

## Bake locally

```bash
docker buildx build --platform linux/amd64 \
  -t brotal/runner-base:dev --load .
```
