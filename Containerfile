FROM ubuntu:latest

ARG RUNNER_VERSION=2.338.1

ENV DEBIAN_FRONTEND=noninteractive
ENV RUSTUP_HOME=/usr/local/rustup
ENV CARGO_HOME=/usr/local/cargo
ENV PATH=/usr/local/cargo/bin:$PATH

RUN apt-get update && apt-get install -y --no-install-recommends \
    # core tools
    bash \
    ca-certificates \
    curl \
    git \
    jq \
    sudo \
    unzip \
    wget \
    xz-utils \
    zip \
    # build tools
    build-essential \
    pkg-config \
    # OS detection (required by actions/setup-*)
    lsb-release \
    dpkg \
    # Python runtime (required by many actions)
    python3 \
    python3-pip \
    python3-venv \
    # Node.js (required by many actions)
    nodejs \
    npm \
    # misc CI utilities
    gnupg \
    ssh-client \
    tar \
    # CI services: client tools the workflows call directly
    postgresql-client \
    ffmpeg \
    # Nested rootless Podman: a private container engine per runner, so jobs never touch the host's containers
    podman \
    fuse-overlayfs \
    uidmap \
    slirp4netns \
    passt \
    iptables \
    nftables \
    crun \
    netavark \
    aardvark-dns \
    && rm -rf /var/lib/apt/lists/*

# Rust toolchain (system-wide)
RUN curl -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path --profile minimal \
    && chmod -R a+rx /usr/local/rustup /usr/local/cargo

# TruffleHog (security scanning)
RUN curl -sSfL https://raw.githubusercontent.com/trufflesecurity/trufflehog/main/scripts/install.sh \
    | sh -s -- -b /usr/local/bin

# `podman compose` uses the docker-compose binary as its provider. Docker CLI and Compose plugin: they talk to the nested Podman's Docker-compatible socket (DOCKER_HOST).
RUN curl -fsSL https://download.docker.com/linux/static/stable/x86_64/docker-27.5.1.tgz \
    | tar -xz --strip-components=1 -C /usr/local/bin docker/docker \
    && mkdir -p /usr/local/lib/docker/cli-plugins \
    && curl -fsSL -o /usr/local/lib/docker/cli-plugins/docker-compose \
       https://github.com/docker/compose/releases/download/v2.32.4/docker-compose-linux-x86_64 \
    && chmod +x /usr/local/lib/docker/cli-plugins/docker-compose \
    && ln -s /usr/local/lib/docker/cli-plugins/docker-compose /usr/local/bin/docker-compose

RUN groupadd --system runner && useradd --system --gid runner --create-home runner

# Passwordless sudo for the runner user (parity with GitHub-hosted runners),
# so workflow steps can `sudo apt-get install` build deps at runtime.
RUN echo 'runner ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/runner \
    && chmod 0440 /etc/sudoers.d/runner

# Subordinate IDs for the nested Podman. The outer container maps IDs 0-65536, so the ranges skip the runner's own ID (999) and stay below 65537; 65534 (nobody) must be mapped for image layers and apt.
# Engine storage lives on a volume (CI_STORAGE) so image pulls survive container recreation.
RUN printf 'runner:1:998\nrunner:1000:64537\n' | tee /etc/subuid > /etc/subgid \
    && mkdir -p /var/lib/ci-containers \
    && chown runner:runner /var/lib/ci-containers \
    && printf '[storage]\ndriver = "overlay"\nrootless_storage_path = "/var/lib/ci-containers"\n[storage.options.overlay]\nmount_program = "/usr/bin/fuse-overlayfs"\n' > /etc/containers/storage.conf \
    && printf '[engine]\ncgroup_manager = "cgroupfs"\nevents_logger = "file"\n[containers]\ncgroups = "disabled"\n' > /etc/containers/containers.conf \
    && printf 'unqualified-search-registries = ["docker.io"]\n' > /etc/containers/registries.conf

WORKDIR /home/runner

RUN curl -fsSL \
    "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz" \
    | tar -xz \
    && chown -R runner:runner /home/runner

RUN ./bin/installdependencies.sh && rm -rf /var/lib/apt/lists/*

COPY --chown=runner:runner entrypoint.sh /home/runner/entrypoint.sh
RUN chmod +x /home/runner/entrypoint.sh

USER runner

ENTRYPOINT ["/home/runner/entrypoint.sh"]

