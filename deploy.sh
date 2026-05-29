#!/usr/bin/env bash
set -euo pipefail

IMAGE_NAME="elixir-ai"
SANDBOX_IMAGE_NAME="elixir-ai-sandbox"
DOCKER_USER="alexmickelson"
TAG=$(date +%Y%m%d%H%M%S)
FULL_IMAGE="${DOCKER_USER}/${IMAGE_NAME}:${TAG}"
FULL_SANDBOX_IMAGE="${DOCKER_USER}/${SANDBOX_IMAGE_NAME}:${TAG}"

docker build -t "${FULL_IMAGE}" .
docker push "${FULL_IMAGE}"

docker build -t "${FULL_SANDBOX_IMAGE}" sandbox/
docker push "${FULL_SANDBOX_IMAGE}"

sed -i "s|image: alexmickelson/elixir-ai:[^ ]*|image: ${FULL_IMAGE}|" kubernetes/statefulset.yml
sed -i "s|image: alexmickelson/elixir-ai-sandbox:[^ ]*|image: ${FULL_SANDBOX_IMAGE}|" kubernetes/sandbox.yml

kubectl apply -f kubernetes/namespace.yml

./kubernetes/create-db-secret.sh
./kubernetes/create-ssh-secret.sh

kubectl create configmap db-schema \
  --namespace=ai-ha-elixir \
  --from-file=schema.sql=postgres/schema/schema.sql \
  --dry-run=client -o yaml | kubectl apply -f -

for f in kubernetes/*.yml; do
  kubectl apply -f "$f"
done
