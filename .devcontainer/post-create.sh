#!/usr/bin/env bash
# Provision the dev environment inside the container.
#
# The image (Dockerfile `os-deps` stage) already carries python 3.11, uv and the
# native libraries the extras need. This script adds the developer toolchain and
# builds the project venv from the workspace.
#
# Overrides:
#   PGPT_DEV_EXTRAS      extras passed to `uv sync` (default: "dev core")
#   PGPT_DEV_PLAYWRIGHT  set to 1 to download the Chromium bundle used by the
#                        web-scraping tool (~150 MB, skipped by default)
set -euo pipefail

EXTRAS=${PGPT_DEV_EXTRAS:-"dev core"}

# Docker initialises a named volume from the image's contents at that path; for
# a path the image does not have (all three below) it creates it root-owned,
# which leaves it read-only for the remote user (`app`, uid 1000). That breaks
# `uv sync` into .venv, the uv cache, and -- least obviously -- Claude Code's
# login, which silently fails to persist ~/.claude/.credentials.json.
# common-utils grants `app` NOPASSWD sudo, so fix the ownership up front.
echo "==> Fixing volume ownership for ${USER:-$(id -un)}"
sudo chown -R "$(id -u):$(id -g)" \
  "${HOME}/.claude" \
  "${HOME}/.cache" \
  /workspaces/private-chat/.venv

echo "==> Installing developer toolchain"
sudo apt-get update -qq
# build-essential/pkg-config are only in the Dockerfile's `dependencies` stage,
# and are needed here for any extra without a prebuilt wheel.
sudo env DEBIAN_FRONTEND=noninteractive apt-get install -yqq --no-install-recommends \
  git \
  build-essential \
  pkg-config \
  zsh \
  less \
  procps
sudo rm -rf /var/lib/apt/lists/*

echo "==> Syncing dependencies (extras: ${EXTRAS})"
extra_flags=()
for extra in ${EXTRAS}; do
  extra_flags+=(--extra "${extra}")
done
# --inexact matches the Makefile's quality-dependencies target: it leaves
# anything already installed in the venv alone instead of pruning it.
uv sync --inexact "${extra_flags[@]}"

# Install the project itself so the `private-gpt` console script is on PATH.
uv pip install --no-deps -e .

echo "==> Preparing data directories"
mkdir -p local_data/tests models

if [[ "${PGPT_DEV_PLAYWRIGHT:-0}" == "1" ]]; then
  echo "==> Installing Playwright Chromium"
  uv run playwright install chromium
fi

echo "==> Verifying the toolchain"
uv run --no-sync ruff --version
uv run --no-sync ty --version
uv run --no-sync python -c "import private_gpt; print('private_gpt import OK')"

cat <<'EOF'

Dev container ready.

  make dev     serve with --reload on container port 8080
               -> UI at http://localhost:18080/ui on the host (see appPort)
  make check   format + lint + typecheck
  make test    full test suite (uses the `test` profile automatically)

PrivateGPT needs an OpenAI-compatible inference server. OPENAI_API_BASE and
OPENAI_EMBEDDING_API_BASE default to http://host.docker.internal:11434/v1
(Ollama on the host), set in .devcontainer/docker-compose.yml. If your server
lives elsewhere, override them per machine -- that file is committed, so keep
machine-specific endpoints out of it:

  - debug sessions: the "env" blocks in .vscode/launch.json (gitignored)
  - terminals:      export OPENAI_API_BASE=... before `make dev`
EOF
