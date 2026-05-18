#!/usr/bin/env bash
set -euo pipefail

## ── colour palette ───────────────────────────────────────
RESET='\033[0m'  BOLD='\033[1m'
RED='\033[0;31m'   GREEN='\033[0;32m'  YELLOW='\033[0;33m'
BLUE='\033[0;34m'  CYAN='\033[0;36m'   DIM='\033[2m'

## ── helpers ──────────────────────────────────────────────
step()  { printf '\n%b==>%b %b%s%b\n' "$CYAN" "$RESET" "$BOLD" "$1" "$RESET"; }
info()  { printf '    %b•%b %s\n'    "$DIM"  "$RESET" "$1"; }
ok()    { printf '    %b✔%b  %s\n'   "$GREEN" "$RESET" "$1"; }
warn()  { printf '    %b⚠%b  %s\n'   "$YELLOW" "$RESET" "$1"; }
err()   { printf '    %b✖%b  %s\n'   "$RED" "$RESET" "$1" >&2; }
die()   { err "$1"; exit 1; }

## ── usage ────────────────────────────────────────────────
usage() {
  printf 'Usage: %s [-n NUM] [-r owner/repo]\n\n' "$(basename "$0")"
  printf '  -n NUM   Number of unique runners to spawn (default: 1)\n'
  printf '  -r REPO  Target GitHub repository (e.g., owner/repo). Fallback: GITHUB_REPO env var.\n'
  printf '  -h       Show this help message\n\n'
  exit 0
}

## ── argument parsing ─────────────────────────────────────
NUM_RUNNERS=1
CLI_TARGET_REPO=""

while getopts ':n:r:h' opt; do
  case "$opt" in
    n)
      [[ "$OPTARG" =~ ^[1-9][0-9]*$ ]] \
        || die "-n requires a positive integer, got: '$OPTARG'"
      NUM_RUNNERS="$OPTARG"
      ;;
    r) CLI_TARGET_REPO="$OPTARG" ;;
    h) usage ;;
    :) die "Option -$OPTARG requires an argument" ;;
    \?) die "Unknown option: -$OPTARG" ;;
  esac
done
shift $((OPTIND - 1))

## ── preflight ────────────────────────────────────────────
[[ -f .env ]]        || die ".env file not found — cannot continue"

# Load .env to capture GITHUB_REPO if present
set -a
source .env
set +a

TARGET_REPO="${CLI_TARGET_REPO:-${GITHUB_REPO:-}}"
[[ -z "$TARGET_REPO" ]] && die "Target repository is required. Provide -r <owner/repo> or set GITHUB_REPO in .env"

command -v gh  &>/dev/null || die "'gh' CLI not found — install it and run 'gh auth login'"
command -v jq  &>/dev/null || die "'jq' not found — install it to parse the token response"

printf '%b%s%b\n' "$BOLD" "━━━  GitHub Actions Runner Deploy  ━━━" "$RESET"
info "Runners to spawn: ${NUM_RUNNERS}"
info "Target repo:      ${TARGET_REPO}"

## ── resource allocation (multi-runner only) ──────────────
RUNNER_CPUS=""
RUNNER_RAM_MB=""

if (( NUM_RUNNERS > 1 )); then
  step "Calculating resource allocation"

  TOTAL_THREADS=$(nproc)
  TOTAL_RAM_MB=$(awk '/MemTotal/{ printf "%d", $2/1024 }' /proc/meminfo)

  RUNNER_CPUS=$(awk "BEGIN { printf \"%.2f\", ${TOTAL_THREADS}/${NUM_RUNNERS} }")
  RUNNER_RAM_MB=$(( TOTAL_RAM_MB / NUM_RUNNERS ))

  info "CPU threads : ${TOTAL_THREADS} total  →  ${RUNNER_CPUS} per runner"
  info "RAM         : ${TOTAL_RAM_MB}MB total  →  ${RUNNER_RAM_MB}MB per runner"

  (( RUNNER_RAM_MB < 256 )) \
    && warn "Per-runner RAM is ${RUNNER_RAM_MB}MB — this may be too low for a stable runner"

  ok "Allocation calculated"
fi

## ── per-runner deploy ────────────────────────────────────
deploy_runner() {
  local idx="$1"

  # Use plain names for a single runner; numbered names for multiples
  if (( NUM_RUNNERS == 1 )); then
    local container_name="gh-runner"
    local runner_name="oracle-instance"
    local env_key="RUNNER_TOKEN"
  else
    local container_name="gh-runner-${idx}"
    local runner_name="oracle-instance-${idx}"
    local env_key="RUNNER_TOKEN_${idx}"
  fi

  ## ── 1. fetch runner registration token ─────────────────
  step "[${idx}/${NUM_RUNNERS}] Fetching runner registration token from GitHub"
  info "Container: ${container_name}"
  info "Runner:    ${runner_name}"

  local runner_token
  runner_token=$(gh api --method POST \
    -H "Accept: application/vnd.github+json" \
    /repos/${TARGET_REPO}/actions/runners/registration-token \
    | jq -r '.token')

  [[ -n "$runner_token" && "$runner_token" != "null" ]] \
    || die "GitHub API returned no token for runner ${idx} — check 'gh auth status' and repo permissions"

  info "Token retrieved (expires in 1 hour)"

  ## update (or append) token key in .env
  if grep -q "^${env_key}=" .env; then
    sed -i "s|^${env_key}=.*|${env_key}=${runner_token}|" .env
    ok "${env_key} updated in .env"
  else
    printf '\n%s=%s\n' "${env_key}" "${runner_token}" >> .env
    ok "${env_key} appended to .env"
  fi

  ## update RUNNER_URL if present in .env
  if grep -q "^RUNNER_URL=" .env; then
    sed -i "s|^RUNNER_URL=.*|RUNNER_URL=https://github.com/${TARGET_REPO}|" .env
  else
    printf '\nRUNNER_URL=https://github.com/%s\n' "${TARGET_REPO}" >> .env
  fi

  ## ── 2. remove old container ────────────────────────────
  step "[${idx}/${NUM_RUNNERS}] Removing existing container '${container_name}' (if any)"
  if podman container rm "${container_name}" 2>/dev/null; then
    ok   "Container removed"
  else
    warn "No existing container found — skipping"
  fi

  ## ── 3. build image (only on first runner) ──────────────
  if (( idx == 1 )); then
    step "[${idx}/${NUM_RUNNERS}] Updating runner version and building image"
    
    local latest_version
    latest_version=$(gh api /repos/actions/runner/releases/latest | jq -r '.tag_name' | sed 's/^v//')
    
    if [[ -n "$latest_version" && "$latest_version" != "null" ]]; then
      info "Latest runner version: ${latest_version}"
      sed -i "s|^ARG RUNNER_VERSION=.*|ARG RUNNER_VERSION=${latest_version}|" Containerfile
      ok "Containerfile updated to v${latest_version}"
    else
      warn "Could not fetch latest runner version — using existing version in Containerfile"
    fi

    info "Tag: localhost/gh-runner"
    podman build -t localhost/gh-runner .
    ok   "Image built successfully"
  else
    info "Reusing already-built image localhost/gh-runner"
  fi

  ## ── 4. create container ────────────────────────────────
  step "[${idx}/${NUM_RUNNERS}] Creating container '${container_name}'"
  info "User:      runner (non-root)"
  info "Env file:  .env"
  info "Read-only: yes  (tmpfs on /tmp)"
  info "Restart:   always"

  # Build args array so resource flags compose cleanly without empty strings
  local -a podman_args=(
    --name            "${container_name}"
    --restart=always
    --env-file        .env
    -e                RUNNER_NAME="${runner_name}"
    --user            runner
    --read-only
    --tmpfs           /tmp:mode=1777
  )

  if (( NUM_RUNNERS > 1 )); then
    podman_args+=(--cpus    "${RUNNER_CPUS}")
    podman_args+=(--memory  "${RUNNER_RAM_MB}m")
    info "CPUs:      ${RUNNER_CPUS}"
    info "Memory:    ${RUNNER_RAM_MB}MB"
  fi

  podman container create --replace "${podman_args[@]}" localhost/gh-runner
  ok "Container created"

  ## ── 5. start container ─────────────────────────────────
  step "[${idx}/${NUM_RUNNERS}] Starting container '${container_name}'"
  podman container start "${container_name}"
  ok   "'${container_name}' is running"
}

## ── main loop ────────────────────────────────────────────
for (( i = 1; i <= NUM_RUNNERS; i++ )); do
  deploy_runner "$i"
done

printf '\n%b%s%b\n\n' "$GREEN$BOLD" \
  "✔  Deploy complete — ${NUM_RUNNERS} runner(s) running" "$RESET"
