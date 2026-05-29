FROM node:25-slim

# Install Python3 (needed for sidecar client) and sound players
RUN apt-get update && apt-get install -y python3 git curl alsa-utils pulseaudio-utils && rm -rf /var/lib/apt/lists/*

# Install project runtimes (customize to your stack)
# RUN apt-get update && apt-get install -y python3-pip && rm -rf /var/lib/apt/lists/*

# Install OpenCode
RUN npm install -g opencode-ai

WORKDIR /workspace
ENV PATH="/workspace/scripts:$PATH"
ENTRYPOINT ["/bin/bash", "-c"]
CMD ["opencode"]
