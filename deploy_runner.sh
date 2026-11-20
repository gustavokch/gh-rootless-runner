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
  printf 'Usage: %s [-n NUM] [-r owner/repo] [-t duration]\n\n' "$(basename "$0")"
  printf '  -n NUM   Number of unique runners to spawn (default: 1)\n'
  printf '  -r REPO  Target GitHub repository (e.g., owner/repo). Fallback: GITHUB_REPO env var.\n'
  printf '  -t TIME  Runner lifetime (e.g., 5m, 12h, 2d). Default: infinite.\n'
  printf '  -h       Show this help message\n\n'
  printf 'Name resolution (RUNNER_NAME in .env):\n'
  printf '  Set          →  single: <name>      multi: <name>-1, <name>-2, …\n'
  printf '  Unset        →  single: gh-runner   multi: gh-runner-1, gh-runner-2, …\n'
  printf '  (runner_name mirrors container_name in both cases)\n\n'
  exit 0
}

## ── argument parsing ─────────────────────────────────────
NUM_RUNNERS=1
CLI_TARGET_REPO=""
RUNNER_TTL=""

while getopts ':n:r:t:h' opt; do
  case "$opt" in
    n)
      [[ "$OPTARG" =~ ^[1-9][0-9]*$ ]] \
        || die "-n requires a positive integer, got: '$OPTARG'"
      NUM_RUNNERS="$OPTARG"
      ;;
    r) CLI_TARGET_REPO="$OPTARG" ;;
    t) RUNNER_TTL="$OPTARG" ;;
    h) usage ;;
    :) die "Option -$OPTARG requires an argument" ;;
    \?) die "Unknown option: -$OPTARG" ;;
  esac
done
shift $((OPTIND - 1))

## ── preflight ────────────────────────────────────────────
[[ -f .env ]] || die ".env file not found — cannot continue"

# Load .env; captures GITHUB_REPO and RUNNER_NAME (if present) into the shell.
set -a
source .env
set +a

TARGET_REPO="${CLI_TARGET_REPO:-${GITHUB_REPO:-}}"
[[ -z "$TARGET_REPO" ]] && die "Target repository is required. Provide -r <owner/repo> or set GITHUB_REPO in .env"

command -v gh &>/dev/null || die "'gh' CLI not found — install it and run 'gh auth login'"
command -v jq &>/dev/null || die "'jq' not found — install it to parse the token response"

GH_TOKEN=$(gh auth token) || die "Could not fetch GitHub token — run 'gh auth login'"

# Derive a stable image base name from RUNNER_NAME so every artefact
# (image tag, default container names) shares the same root and no
# "gh-runner" literal survives in a nameable deployment.
IMAGE_BASE="${RUNNER_NAME:-gh-runner}"
IMAGE_TAG="localhost/${IMAGE_BASE}"

printf '%b%s%b\n' "$BOLD" "━━━  GitHub Actions Runner Deploy  ━━━" "$RESET"
info "Runners to spawn: ${NUM_RUNNERS}"
info "Target repo:      ${TARGET_REPO}"
[[ -n "${RUNNER_NAME:-}" ]] && info "Runner base name: ${RUNNER_NAME} (from .env)"
[[ -n "$RUNNER_TTL" ]]     && info "TTL:              ${RUNNER_TTL}"

## ── resource allocation (multi-runner only) ──────────────
RUNNER_CPUS=""
RUNNER_RAM_MB=""

if (( NUM_RUNNERS > 1 )); then
  step "Calculating resource allocation"

  TOTAL_THREADS=$(nproc)
  TOTAL_RAM_MB=$(awk '/MemTotal/{ printf "%d", $2/1024 }' /proc/meminfo)

  RUNNER_CPUS=$(awk "BEGIN { printf \"%.2f\", ${TOTAL_THREADS}/${NUM_RUNNERS} }")
  RUNNER_RAM_MB=$(( (TOTAL_RAM_MB - 2048) / NUM_RUNNERS ))  # Reserve 2GB for host

  info "CPU threads : ${TOTAL_THREADS} total  →  ${RUNNER_CPUS} per runner"
  info "RAM         : ${TOTAL_RAM_MB}MB total  →  ${RUNNER_RAM_MB}MB per runner"

  (( RUNNER_RAM_MB < 256 )) \
    && warn "Per-runner RAM is ${RUNNER_RAM_MB}MB — this may be too low for a stable runner"

  ok "Allocation calculated"
fi

## ── per-runner deploy ────────────────────────────────────
deploy_runner() {
  local idx="$1"
  local base="${RUNNER_NAME:-}"   # populated from .env via source above
  local container_name runner_name

  # Derive names from RUNNER_NAME in .env when set; fall back to hardcoded
  # defaults otherwise.  In multi-runner mode a numeric suffix is appended.
  #
  #   RUNNER_NAME set,   single  →  <name>          / <name>
  #   RUNNER_NAME set,   multi   →  <name>-<idx>    / <name>-<idx>
  #   RUNNER_NAME unset, single  →  gh-runner        / gh-vps
  #   RUNNER_NAME unset, multi   →  gh-runner-<idx>  / gh-vps-<idx>
  if [[ -n "$base" ]]; then
    if (( NUM_RUNNERS > 1 )); then
      container_name="${base}-${idx}"
      runner_name="${base}-${idx}"
    else
      container_name="$base"
      runner_name="$base"
    fi
  elif (( NUM_RUNNERS == 1 )); then
    container_name="${IMAGE_BASE}"
    runner_name="gh-vps"
  else
    container_name="${IMAGE_BASE}-${idx}"
    runner_name="gh-vps-${idx}"
  fi

  ## ── 1. sync RUNNER_URL in .env ─────────────────────────
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

    info "Tag: ${IMAGE_TAG}"
    podman build -t "${IMAGE_TAG}" .
    ok   "Image built successfully"
  else
    info "Reusing already-built image ${IMAGE_TAG}"
  fi

  ## ── 4. create container ────────────────────────────────
  step "[${idx}/${NUM_RUNNERS}] Creating container '${container_name}'"
  info "Runner name: ${runner_name}"
  info "User:        runner (non-root)"
  info "Env file:    .env"
  info "Read-only:   no   (immutable image + ephemeral container layer; tmpfs /tmp)"
  info "Restart:     always"

  # Build args array so resource flags compose cleanly without empty strings.
  # -e RUNNER_NAME overrides whatever .env might contain, ensuring the
  # per-instance name (with numeric suffix when NUM_RUNNERS > 1) wins.
  local -a podman_args=(
    --name            "${container_name}"
    --restart=always
    --env-file        .env
    -e                RUNNER_NAME="${runner_name}"
    -e                GH_TOKEN="${GH_TOKEN}"
    -e                TARGET_REPO="${TARGET_REPO}"
    -e                RUNNER_TTL="${RUNNER_TTL}"
    --user            runner
    --tmpfs           /tmp:mode=1777
    # Nested Podman: SYS_ADMIN (scoped to the rootless user namespace, not the host) lets newuidmap build the inner namespace; unmask=ALL makes /proc/sys writable for netavark bridges;
    # /dev/fuse for fuse-overlayfs; /dev/net/tun for pasta networking; a per-container volume for the private engine's image cache
    # (two engines must never share one storage directory).
    --device          /dev/fuse
    --device          /dev/net/tun
    --security-opt    label=disable
    --cap-add         SYS_ADMIN
    --security-opt    unmask=ALL
    --volume          "${container_name}-ci-storage:/var/lib/ci-containers"
  )

  if (( NUM_RUNNERS > 1 )); then
    podman_args+=(--cpus   "${RUNNER_CPUS}")
    podman_args+=(--memory "${RUNNER_RAM_MB}m")
    info "CPUs:        ${RUNNER_CPUS}"
    info "Memory:      ${RUNNER_RAM_MB}MB"
  fi

  podman container create --replace "${podman_args[@]}" "${IMAGE_TAG}"
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

