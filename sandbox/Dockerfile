FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
  bash \
  coreutils \
  grep \
  sed \
  gawk \
  findutils \
  curl \
  wget \
  git \
  jq \
  tree \
  file \
  less \
  procps \
  ca-certificates \
  && rm -rf /var/lib/apt/lists/*

# Overflow mode writes full output here for the agent to explore later
RUN mkdir -p /tmp/cmd-output

# Create a non-root user for the sandbox
RUN useradd -m -s /bin/bash sandbox
USER sandbox
WORKDIR /home/sandbox

# Container does nothing on its own. Commands injected via `docker exec`.
CMD ["sleep", "infinity"]
