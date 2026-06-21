# Ephemeral, root self-hosted GitHub Actions runners using Podman

Deploy ephemeral, rootless GitHub Actions runners using Podman with automated token management and resource allocation. Runners execute in isolated containers with tmpfs mounts for security and state isolation. The deployment script builds a local image and runs one or more rootless Podman containers that register as ephemeral self-hosted runners with GitHub.

## Prerequisites

- **[Podman](https://podman.io/)**: For rootless container execution.
- **[GitHub CLI (`gh`)](https://cli.github.com/)**: To fetch runner registration tokens.
  - You must authenticate first: `gh auth login`
- **[`jq`](https://jqlang.github.io/jq/)**: To parse the token JSON response from the GitHub API.

## Setup

1. Copy the example environment file:
   ```bash
   cp .env.example .env
   ```
2. (Optional) Set your default target repository in `.env`:
   ```env
   GITHUB_REPO=your-user/your-repo
   ```
   *Note: Real runner tokens will be written to `.env` automatically when the deployment script runs. This file is ignored by git.*

3. (Optional) Set a base name for your runner(s) in `.env` using `RUNNER_NAME`:
   ```env
   RUNNER_NAME=my-ci-runner
   ```
   When set, the script derives container and runner names from this value (see Name resolution below). If unset, reasonable defaults are used (e.g. `gh-runner`, `gh-vps`).

## Usage

The `deploy_runner.sh` script automates fetching tokens via the GitHub API, building the Podman image, and running the container(s).

### Basic Deployment

Deploy a single runner for a specific repository:

```bash
./deploy_runner.sh -r owner/repo
```

If you configured `GITHUB_REPO` in your `.env`, you can omit the `-r` flag:

```bash
./deploy_runner.sh
```

### Multiple Runners

You can deploy multiple runners for the same repository simultaneously by specifying the `-n` flag. The script will automatically calculate CPU and RAM limits to distribute your host's resources evenly among instances.

```bash
# Deploy 4 runners
./deploy_runner.sh -n 4 -r owner/repo
```

### Name resolution (RUNNER_NAME in .env)

The script supports a `RUNNER_NAME` value in `.env` to make naming predictable when deploying multiple instances. Behavior:

- Set → single: <name>      multi: <name>-1, <name>-2, …
- Unset → single: gh-runner  multi: gh-runner-1, gh-runner-2, …

The per-runner `RUNNER_NAME` value also mirrors the container name and is passed to the runner process (overriding any value in `.env`), ensuring each instance registers with a unique name when multiple runners are created.

### Runner lifetime (JIT looping, TTL) and JIT fetch behavior

The script supports a time-to-live for runners using the `-t TIME` flag (for example `5m`, `12h`, `2d`), which configures how long a launched runner should remain active. This enables looping JIT-style deployments where the script can create ephemeral runners that unregister and exit after the configured TTL.

Under the hood the deployment includes improved JIT fetch logic with exponential backoff and enhanced logging to make token retrieval and transient network errors more resilient and easier to diagnose.

## How It Works

1. **Token Retrieval**: The script uses `gh api` to fetch ephemeral runner registration tokens. The token handling and JIT fetch logic include retries with exponential backoff and clearer logging on failure.
2. **Container Build & Runner Versioning**: A custom Ubuntu-based image is built containing Node.js, Python, Rust, and other CI tools (defined in `Containerfile`). The script checks the GitHub Actions runner releases and will attempt to update the `ARG RUNNER_VERSION` in `Containerfile` to the latest available release before building. The image is tagged `localhost/<base>` where `<base>` is derived from `RUNNER_NAME` when present, otherwise `gh-runner`.
3. **Rootless Execution**: `podman` creates the runner instances in rootless mode with limited privileges.
4. **Ephemeral Configuration**: When a container starts, `entrypoint.sh` initializes the runner config using `--ephemeral` (one-job lifecycle) if configured, ensuring it only runs one job before unregistering and exiting. The container is started read-only with tmpfs for writable runtime data to minimize state leakage.

## Notes & Tips

- The script will update `RUNNER_URL` in your `.env` to point to the target repository being deployed to.
- Image tagging uses `localhost/<name>` so local images are easy to identify and do not collide with remote registries.
- When deploying many runners, ensure your host has enough CPU and RAM; the script will attempt to split resources across instances but cannot exceed the physical limits of the host.

---

For full details, check `deploy_runner.sh`, `Containerfile`, and `entrypoint.sh` in the repository.
