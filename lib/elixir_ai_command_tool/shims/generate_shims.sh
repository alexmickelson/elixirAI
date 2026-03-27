#!/usr/bin/env bash
# Generates shim symlinks in /app/shims pointing to runner.sh.
# Add command names to the SHIMS array to intercept them.
set -e

SHIM_DIR="/app/shims"
SHIMS=(cat grep head tail wc find ls sed awk sort uniq tr cut tee xargs)

mkdir -p "$SHIM_DIR"

for cmd in "${SHIMS[@]}"; do
  ln -sf runner.sh "$SHIM_DIR/$cmd"
done

echo "Generated ${#SHIMS[@]} shims in $SHIM_DIR"
