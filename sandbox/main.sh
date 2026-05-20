#!/bin/bash
set -e

# Wait for the Nix daemon socket
for i in $(seq 1 60); do
  [ -S /nix/var/nix/daemon-socket/socket ] && break
  sleep 0.5
done

if [ ! -S /nix/var/nix/daemon-socket/socket ]; then
  echo "ERROR: Nix daemon socket never appeared" >&2
  exit 1
fi

# Run CMD passed from entrypoint via environment
exec runuser -u sandbox -- env PATH="/nix/var/nix/profiles/default/bin:$PATH" bash -c "${SANDBOX_CMD:-sleep infinity}"
