FROM node:25-slim

# Install Python3, tools, and just command runner
RUN apt-get update && apt-get install -y python3 git curl alsa-utils pulseaudio-utils xz-utils && rm -rf /var/lib/apt/lists/*
RUN ARCH=$(uname -m) && case "$ARCH" in x86_64) T=x86_64-unknown-linux-musl ;; aarch64) T=aarch64-unknown-linux-musl ;; *) echo "unsupported arch: $ARCH" >&2; exit 1 ;; esac && curl -L "https://github.com/casey/just/releases/download/1.42.0/just-1.42.0-${T}.tar.gz" | tar xz -C /usr/local/bin just

# Install Nix (single-user, no daemon) for nix-instantiate syntax checks
RUN mkdir -m 0755 /nix && groupadd -r nixbld && for i in $(seq 1 10); do useradd -r -g nixbld -G nixbld -d /var/empty -s /usr/sbin/nologin "nixbld${i}"; done && curl -L https://nixos.org/nix/install | sh -s -- --no-daemon
ENV PATH="/root/.nix-profile/bin:$PATH"

# Install project runtimes (customize to your stack)
# RUN apt-get update && apt-get install -y python3-pip && rm -rf /var/lib/apt/lists/*

# Install OpenCode
RUN npm install -g opencode-ai

WORKDIR /workspace
ENV PATH="/workspace/scripts:$PATH"
ENTRYPOINT ["/bin/bash", "-c"]
CMD ["opencode"]
