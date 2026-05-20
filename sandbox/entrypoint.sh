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

# Pass CMD args to main.sh via environment so supervisord can forward them
export SANDBOX_CMD="$*"

exec supervisord -c /etc/supervisor/conf.d/sandbox.conf

