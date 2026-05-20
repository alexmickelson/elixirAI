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
  xz-utils \
  supervisor \
  && rm -rf /var/lib/apt/lists/*

RUN useradd -m -s /bin/bash sandbox

# Install Nix via Determinate installer (multi-user, no init system)
RUN curl -sSfL https://install.determinate.systems/nix | sh -s -- install linux \
  --no-confirm \
  --init none \
  --extra-conf "sandbox = false" \
  && groupadd -f nix-users \
  && usermod -aG nix-users sandbox

ENV PATH="/nix/var/nix/profiles/default/bin:$PATH"

# Enable flakes and allow unfree packages for sandbox user
RUN mkdir -p /home/sandbox/.config/nix /home/sandbox/.config/nixpkgs /home/sandbox/.agent \
  && echo 'experimental-features = nix-command flakes' > /home/sandbox/.config/nix/nix.conf \
  && printf '{ allowUnfree = true; }\n' > /home/sandbox/.config/nixpkgs/config.nix \
  && chown -R sandbox:sandbox /home/sandbox/.config /home/sandbox/.agent

COPY environment-skill.md /home/sandbox/.agents/skills/environment/SKILL.md
RUN chown sandbox:sandbox /home/sandbox/.agents/skills/environment/SKILL.md

# Backup home directory files so they can be restored after the volume mount wipes /home/sandbox
RUN cp -a /home/sandbox/. /home/sandbox-defaults/

# Backup /nix so it can be restored if a fresh empty volume is mounted over it
RUN cp -a /nix/. /nix-defaults/

COPY entrypoint.sh /entrypoint.sh
COPY main.sh /main.sh
COPY supervisord.conf /etc/supervisor/conf.d/sandbox.conf
RUN chmod +x /entrypoint.sh /main.sh

WORKDIR /home/sandbox
USER sandbox

ENTRYPOINT ["/entrypoint.sh"]
CMD ["sleep", "infinity"]
