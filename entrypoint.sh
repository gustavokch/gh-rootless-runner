#!/usr/bin/env bash
set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN environment variable is required}"
: "${TARGET_REPO:?TARGET_REPO environment variable is required}"
RUNNER_NAME="${RUNNER_NAME:-$(hostname)}"
RUNNER_TTL="${RUNNER_TTL:-}"

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

# Nested rootless Podman: a private, Docker-compatible engine inside this container.
# Workflow services, `docker build` and `docker compose` run here, never on the host.
export XDG_RUNTIME_DIR=/tmp/run
mkdir -p "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR"
export DOCKER_HOST="unix://${XDG_RUNTIME_DIR}/podman.sock"
# Each job starts with an empty engine and an empty /tmp, as on a GitHub-hosted runner (reset_engine and reset_tmp,
# run before every job). A job cancelled or killed mid-run leaves its service containers and Compose stacks running,
# and the next job's `services:` container then cannot bind the same port. /tmp is a tmpfs that counts against this
# container's memory limit, so caches that grow there from job to job end in OOM kills. The engine's storage shares
# the host's disk, so an image a build replaced (dangling) goes too; the build cache and pulled images stay. sudo: a
# job's root-owned files, the read-only Go module cache and files the nested containers wrote under subordinate IDs
# are not the runner user's to remove.
reset_engine() {
    podman rm --force --all >/dev/null 2>&1 || true
    podman volume prune --force >/dev/null 2>&1 || true
    podman network prune --force >/dev/null 2>&1 || true
    podman image prune --force >/dev/null 2>&1 || true
}
reset_tmp() {
    find /tmp -mindepth 1 -maxdepth 1 \
        ! -name runner ! -name rustup ! -name cargo ! -name run ! -name podman-service.log \
        -exec sudo -n rm -rf {} + >/dev/null 2>&1 || true
    mkdir -p "$HOME" "$npm_config_cache" "$npm_config_prefix" "$UV_CACHE_DIR" "$PIP_CACHE_DIR" \
        "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME"
}
podman system service --time=0 "$DOCKER_HOST" >/tmp/podman-service.log 2>&1 &
for _ in $(seq 1 30); do
    docker info >/dev/null 2>&1 && break
    sleep 1
done
docker info >/dev/null 2>&1 || { echo "Error: nested Podman engine did not start"; cat /tmp/podman-service.log; exit 1; }
echo "Nested Podman engine is ready."
# Podman runs a container's health check from a systemd timer, and this container has no systemd, so a
# `--health-cmd` (Actions service containers, Compose `healthcheck`) would stay "starting" forever. Run the checks
# here, each one --health-interval after the last, as Docker does (30 s when unset): run more often, the checks spend
# a slow service's --health-retries early and mark it unhealthy.
(
    declare -A interval=() due=()
    while true; do
        now=$(date +%s)
        declare -A seen=()
        for id in $(podman ps --quiet --filter health=starting --filter health=healthy --filter health=unhealthy \
            2>/dev/null); do
            seen[$id]=1
            if [[ -z "${interval[$id]:-}" ]]; then
                secs=$(podman inspect --format '{{.Config.Healthcheck.Interval.Seconds}}' "$id" 2>/dev/null) || continue
                secs=${secs%.*}
                [[ "$secs" =~ ^[0-9]+$ ]] && (( secs >= 1 )) || secs=30
                interval[$id]=$secs
                due[$id]=$(( now + secs ))
            fi
            if (( now >= due[$id] )); then
                podman healthcheck run "$id" >/dev/null 2>&1 || true
                due[$id]=$(( $(date +%s) + interval[$id] ))
            fi
        done
        for id in "${!interval[@]}"; do
            [[ -n "${seen[$id]:-}" ]] || unset "interval[$id]" "due[$id]"
        done
        unset seen
        sleep 1
    done
) &

parse_ttl() {
    local ttl="$1"
    [[ -z "$ttl" ]] && echo "0" && return
    
    local value="${ttl%[a-z]*}"
    local unit="${ttl##*[0-9]}"
    
    case "$unit" in
        s) echo "$value" ;;
        m) echo $((value * 60)) ;;
        h) echo $((value * 3600)) ;;
        d) echo $((value * 86400)) ;;
        *) echo "$value" ;; # Default to seconds if no unit
    esac
}

TTL_SECONDS=$(parse_ttl "$RUNNER_TTL")
START_TIME=$(date +%s)

cleanup() {
    echo "Exiting runner..."
}
trap cleanup EXIT INT TERM

cp -r /home/runner/. /tmp/runner/
cd /tmp/runner

INITIAL_RETRY_DELAY=10
MAX_RETRY_DELAY=300
RETRY_DELAY=$INITIAL_RETRY_DELAY

while true; do
    echo "Fetching runner JIT configuration from GitHub..."
    
    # Use a temporary file to capture the response body
    RESPONSE_FILE=$(mktemp)
    HTTP_STATUS=$(curl -s -o "$RESPONSE_FILE" -w "%{http_code}" -X POST \
        -H "Accept: application/vnd.github+json" \
        -H "Authorization: Bearer $GH_TOKEN" \
        "https://api.github.com/repos/${TARGET_REPO}/actions/runners/generate-jitconfig" \
        -d "{\"name\":\"${RUNNER_NAME}\",\"runner_group_id\":1,\"labels\":[\"self-hosted\",\"linux\",\"x64\"],\"work_folder\":\"_work\"}")

    JIT_CONFIG=$(jq -r '.encoded_jit_config' "$RESPONSE_FILE" 2>/dev/null || echo "null")
    
    if [[ "$HTTP_STATUS" -ne 201 ]] || [[ -z "$JIT_CONFIG" || "$JIT_CONFIG" == "null" ]]; then
        echo "Error: Failed to fetch JIT configuration (HTTP $HTTP_STATUS)."
        if [[ -s "$RESPONSE_FILE" ]]; then
            echo "Response: $(cat "$RESPONSE_FILE")"
        fi
        rm -f "$RESPONSE_FILE"

        echo "Retrying in ${RETRY_DELAY} seconds..."
        sleep "$RETRY_DELAY"
        RETRY_DELAY=$(( RETRY_DELAY * 2 ))
        if [[ "$RETRY_DELAY" -gt "$MAX_RETRY_DELAY" ]]; then
            RETRY_DELAY=$MAX_RETRY_DELAY
        fi
        continue
    fi
    rm -f "$RESPONSE_FILE"
    
    # Reset backoff on success
    RETRY_DELAY=$INITIAL_RETRY_DELAY

    reset_engine
    reset_tmp

    echo "Starting runner..."
    ./run.sh --jitconfig "${JIT_CONFIG}" || echo "Runner exited with error"

    # Mandatory cooldown to prevent rapid restart loops if runner crashes
    sleep 5

    if [[ "$TTL_SECONDS" -gt 0 ]]; then
        CURRENT_TIME=$(date +%s)
        ELAPSED=$((CURRENT_TIME - START_TIME))
        if [[ "$ELAPSED" -ge "$TTL_SECONDS" ]]; then
            echo "TTL of ${RUNNER_TTL} reached. Exiting."
            break
        fi
        echo "Time remaining: $((TTL_SECONDS - ELAPSED)) seconds."
    fi
    
    echo "Job completed. Looping for next job..."
done
