#!/bin/bash
set -e

# Restore a directory from its backup only if the target is empty (fresh volume)
# Usage: restore_if_empty <backup-src> <target-dir> [owner]
restore_if_empty() {
  local src="$1"
  local dst="$2"
  local owner="$3"

  [ -d "$src" ] || return 0

  # Count non-hidden entries; empty volume will have none (or only lost+found)
  local count
  count=$(find "$dst" -mindepth 1 -maxdepth 1 ! -name 'lost+found' 2>/dev/null | wc -l)

  if [ "$count" -eq 0 ]; then
    echo "[entrypoint] $dst is empty — restoring from $src"
    cp -a "$src/." "$dst/"
    [ -n "$owner" ] && chown -R "$owner" "$dst"
  else
    echo "[entrypoint] $dst already has content — skipping restore"
  fi
}

restore_if_empty /nix-defaults /nix
restore_if_empty /home/sandbox-defaults /home/sandbox sandbox:sandbox

# Generate SSH host keys if not already present
ssh-keygen -A 2>/dev/null || true

# Set up sandbox user SSH authorized_keys
mkdir -p /home/sandbox/.ssh
chmod 700 /home/sandbox/.ssh

if [ -d /ssh_keys ]; then
  # Docker Compose: generate key pair in shared volume on first start
  if [ ! -f /ssh_keys/id_ed25519 ]; then
    echo "[entrypoint] Generating SSH key pair in /ssh_keys"
    ssh-keygen -t ed25519 -f /ssh_keys/id_ed25519 -N "" -C "sandbox@llm"
    chmod 600 /ssh_keys/id_ed25519
  fi
  cat /ssh_keys/id_ed25519.pub > /home/sandbox/.ssh/authorized_keys
fi

if [ -f /run/secrets/sandbox_ssh_pubkey ]; then
  # Kubernetes: public key mounted from secret
  echo "[entrypoint] Installing SSH public key from secret"
  cat /run/secrets/sandbox_ssh_pubkey > /home/sandbox/.ssh/authorized_keys
fi

if [ -f /home/sandbox/.ssh/authorized_keys ]; then
  chmod 600 /home/sandbox/.ssh/authorized_keys
fi
chown -R sandbox:sandbox /home/sandbox/.ssh

# Pass CMD args to main.sh via environment so supervisord can forward them
export SANDBOX_CMD="$*"

exec supervisord -c /etc/supervisor/conf.d/sandbox.conf

