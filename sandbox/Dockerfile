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
  sudo \
  && rm -rf /var/lib/apt/lists/* \
  && echo "sandbox ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/sandbox \
  && chmod 0440 /etc/sudoers.d/sandbox

RUN mkdir -p /tmp/cmd-output

RUN useradd -m -s /bin/bash sandbox
USER sandbox
WORKDIR /home/sandbox

CMD ["sleep", "infinity"]
