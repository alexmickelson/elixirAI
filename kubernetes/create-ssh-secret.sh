#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="ai-ha-elixir"
SECRET_NAME="sandbox-ssh-secret"

if kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" &>/dev/null; then
  echo "Secret '$SECRET_NAME' already exists in namespace '$NAMESPACE', skipping creation."
  exit 0
fi

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

ssh-keygen -t ed25519 -f "$TMPDIR/id_ed25519" -N "" -C "sandbox@kubernetes"

kubectl create secret generic "$SECRET_NAME" \
  --namespace="$NAMESPACE" \
  --from-file=private_key="$TMPDIR/id_ed25519" \
  --from-file=public_key="$TMPDIR/id_ed25519.pub"

echo "Secret '$SECRET_NAME' created successfully in namespace '$NAMESPACE'."
