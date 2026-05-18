FROM ubuntu:latest

ARG RUNNER_VERSION=2.333.1

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
    && rm -rf /var/lib/apt/lists/*

# Rust toolchain (system-wide)
RUN curl -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path --profile minimal \
    && chmod -R a+rx /usr/local/rustup /usr/local/cargo

# TruffleHog (security scanning)
RUN curl -sSfL https://raw.githubusercontent.com/trufflesecurity/trufflehog/main/scripts/install.sh \
    | sh -s -- -b /usr/local/bin

RUN groupadd --system runner && useradd --system --gid runner --create-home runner

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

