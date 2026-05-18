#!/usr/bin/env bash
set -euo pipefail

: "${RUNNER_URL:?RUNNER_URL environment variable is required}"
: "${RUNNER_TOKEN:?RUNNER_TOKEN environment variable is required}"
RUNNER_NAME="${RUNNER_NAME:-$(hostname)}"
RUNNER_LABELS="${RUNNER_LABELS:-}"

# Redirect all tool home/cache dirs to writable tmpfs
export HOME=/tmp/home
export npm_config_cache=/tmp/npm-cache
export npm_config_prefix=/tmp/npm-global
export CARGO_HOME=/tmp/cargo
export RUSTUP_HOME=/tmp/rustup
export UV_CACHE_DIR=/tmp/uv-cache
export PIP_CACHE_DIR=/tmp/pip-cache
export XDG_CACHE_HOME=/tmp/cache
export XDG_CONFIG_HOME=/tmp/config
export XDG_DATA_HOME=/tmp/data

mkdir -p \
    /tmp/home \
    /tmp/npm-cache \
    /tmp/npm-global \
    /tmp/uv-cache \
    /tmp/pip-cache \
    /tmp/cache \
    /tmp/config \
    /tmp/data \
    /tmp/runner

# Copy rustup and cargo from image into writable tmpfs so toolchains are available
cp -r /usr/local/rustup/. /tmp/rustup/
cp -r /usr/local/cargo/.  /tmp/cargo/

# Ensure cargo/rustup bins are on PATH
export PATH=/tmp/cargo/bin:$PATH

cleanup() {
    echo "Removing runner registration..."
    cd /tmp/runner
    ./config.sh remove --token "${RUNNER_TOKEN}" || true
}
trap cleanup EXIT INT TERM

cp -r /home/runner/. /tmp/runner/
cd /tmp/runner

./config.sh \
    --unattended \
    --url "${RUNNER_URL}" \
    --token "${RUNNER_TOKEN}" \
    --name "${RUNNER_NAME}" \
    --labels "${RUNNER_LABELS}" \
    --replace \
    --ephemeral

exec ./run.sh

