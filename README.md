# Self-Hosted GitHub Actions Runner Setup

This repository contains scripts to automatically build and deploy ephemeral, rootless [GitHub Actions runners](https://docs.github.com/en/actions/hosting-your-own-runners) using Podman.

The runners are deployed securely with `tmpfs` mounts, making them effectively read-only and ephemeral, to prevent job state leakage between runs. 

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

You can deploy multiple runners for the same repository simultaneously by specifying the `-n` flag. The script will automatically calculate CPU and RAM limits to distribute your host's resources evenly among them.

```bash
# Deploy 4 runners
./deploy_runner.sh -n 4 -r owner/repo
```

## How It Works

1. **Token Retrieval**: The script uses `gh api` to fetch ephemeral runner registration tokens.
2. **Container Build**: A custom Ubuntu-based image is built containing Node.js, Python, Rust, and other CI tools (defined in `Containerfile`).
3. **Rootless Execution**: `podman` creates the runner instances in rootless mode with limited privileges.
4. **Ephemeral Configuration**: When a container starts, `entrypoint.sh` initializes the runner config using `--ephemeral`, ensuring it only runs one job before unregistering and exiting. The container's restart policy automatically spins it back up to fetch the next job.
