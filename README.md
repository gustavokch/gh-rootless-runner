# Ephemeral, root self-hosted GitHub Actions runners using Podman

Deploy ephemeral, rootless GitHub Actions runners using Podman with automated token management and resource allocation. Runners execute in isolated containers with tmpfs mounts for security and state isolation. The deployment script builds a local image and runs one or more rootless Podman containers that register as ephemeral self-hosted runners with GitHub.

## Prerequisites

- **[Podman](https://podman.io/)**: For rootless container execution. Run `deploy_runner.sh` as a non-root user: it refuses to run under root (see [Nested container engine and privileges](#nested-container-engine-and-privileges)).
- **Host**: `/dev/fuse` and `/dev/net/tun`, and a subordinate ID range of at least 65536 IDs for the deploying user in `/etc/subuid` and `/etc/subgid` (the default for new users). The runner image maps container IDs 0-65536.
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
3. **Rootless Execution**: `podman` creates the runner instances in rootless mode. Each runner container gets the extra privileges its nested container engine needs, confined to the deploying user's namespace (see [Nested container engine and privileges](#nested-container-engine-and-privileges)).
4. **Ephemeral Configuration**: When a container starts, `entrypoint.sh` initializes the runner config using `--ephemeral` (one-job lifecycle) if configured, ensuring it only runs one job before unregistering and exiting. The image itself is immutable; the container's rootfs is a throwaway overlay layer (image = lower, container layer = upper) discarded when the container is recreated (`--replace` on deploy, or TTL exit), with `/tmp` on tmpfs. The nested engine's storage volume is the exception (see [Engine storage](#engine-storage)). This lets workflow steps `sudo apt-get install` build deps at runtime while keeping the base image clean. Before every job, `entrypoint.sh` also clears what earlier jobs left behind (see [Between jobs](#between-jobs)).

## Nested container engine and privileges

Each runner container runs its own rootless Podman engine, with a Docker-compatible socket (`DOCKER_HOST`) and the Docker CLI and Compose plugin as its clients. Workflow `services:`, `docker build` and `docker compose` run on this engine, so a job's containers and published ports never reach the host's other containers or the other runners.

The engine needs these options on each runner container (`deploy_runner.sh`):

| Option | Why |
|---|---|
| `--cap-add SYS_ADMIN` | Lets `newuidmap` build the engine's user namespace. Rootless Podman confines it to the deploying user's namespace; under root it would act on the host, so the script refuses root. |
| `--security-opt unmask=ALL` | Makes `/proc/sys` writable, which netavark needs to set up bridge networks. |
| `--security-opt label=disable` | Turns off SELinux separation, which would block the engine's mounts. No effect on hosts without SELinux. |
| `--device /dev/fuse` | fuse-overlayfs, the engine's storage driver. |
| `--device /dev/net/tun` | pasta, the engine's rootless networking. |

These are more privileges than a plain rootless container has: a job can create namespaces and mounts inside its runner container. Run only workflows you trust on these runners; for a public repository, do not let pull requests from forks run on them.

### Engine storage

The engine keeps its images in a named volume per runner container, `<container>-ci-storage`, mounted at `/var/lib/ci-containers`. Unlike the container layer and `/tmp`, the volume survives redeploys, so tagged images, pulled or built, are kept. It grows on the host's disk with the images jobs pull and build. When you remove a runner, or redeploy with a smaller `-n` or another `RUNNER_NAME`, remove its volume:

```bash
podman volume rm <container>-ci-storage
```

## Between jobs

A runner container runs jobs one after another for as long as it lives. Before every job, `entrypoint.sh` clears what earlier jobs left behind:

- **Engine:** every container, including a cancelled job's service containers and those an interrupted build left behind; unused volumes and networks; untagged images, which are images a build replaced and the cached layers of a multi-stage build's earlier stages. Tagged images stay.
- **`/tmp`:** emptied, and the tool caches (`HOME`, npm, pip, uv, `XDG_*`) recreated empty. The runner directory stays, and its `_work` keeps the actions, the tool cache and the last workspace. The Rust toolchain, cargo's registry cache and the engine's runtime directory stay too. Registry logins a job made (`docker login`, `podman login`, cargo tokens) go.

Unlike on a GitHub-hosted runner, a job can still see what earlier jobs left in the workspace, the tool cache and the engine's tagged images. For a fresh machine per job, recreate the container per job.

## Notes & Tips

- The script will update `RUNNER_URL` in your `.env` to point to the target repository being deployed to.
- Image tagging uses `localhost/<name>` so local images are easy to identify and do not collide with remote registries.
- When deploying many runners, ensure your host has enough CPU and RAM; the script will attempt to split resources across instances but cannot exceed the physical limits of the host.

---

For full details, check `deploy_runner.sh`, `Containerfile`, and `entrypoint.sh` in the repository.
