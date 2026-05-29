#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="ai-ha-elixir"
SECRET_NAME="db-secret"
DB_USER="elixir_ai"
DB_NAME="elixir_ai"
DB_HOST="postgres"

if kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" &>/dev/null; then
  echo "Secret '$SECRET_NAME' already exists in namespace '$NAMESPACE', skipping creation."
  exit 0
fi

DB_PASSWORD=$(openssl rand -base64 48 | tr -d '/+=' | head -c 40)
DATABASE_URL="ecto://${DB_USER}:${DB_PASSWORD}@${DB_HOST}/${DB_NAME}"

kubectl create secret generic "$SECRET_NAME" \
  --namespace="$NAMESPACE" \
  --from-literal=POSTGRES_PASSWORD="$DB_PASSWORD" \
  --from-literal=DATABASE_URL="$DATABASE_URL"

echo "Secret '$SECRET_NAME' created successfully in namespace '$NAMESPACE'."
