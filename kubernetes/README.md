# Kubernetes Deployment with Istio

This directory contains the Kubernetes manifests for deploying elixirAI with an **Istio service mesh**.

## Architecture

```
                          ┌───────────────┐
  $INGRESS_HOST ─────────▶│  Istio        │
  (e.g. ai.example.com)   │  Gateway      │
                          └───────┬───────┘
                                  │ HTTP/80
                          ┌───────▼───────┐
                          │ VirtualService│──→ retries, timeouts, outlier detection
                          └───────┬───────┘
                                  │
                    ┌─────────────┴─────────────┐
                    │   Service: ai-ha-elixir    │
                    │   (ClusterIP, port 80)     │
                    └─────────────┬─────────────┘
                                  │
                   ┌──────────────┼──────────────┐
                   │              │              │
            ┌──────▼──────┐ ┌────▼─────┐  ...   │
            │ Pod (node1) │ │ Pod(n2)  │        │
            │ ┌─────────┐ │ │ ┌───────┐│        │
            │ │ Elixir  │ │ │ │Elixir ││        │
            │ │ :4000   │ │ │ │:4000  ││        │
            │ │ Envoy↕️ │ │ │ │Envoy↕️││        │
            │ └─────────┘ │ │ └───────┘│        │
            │ :4369 EPMD  │ │ :4369    │        │ ← excluded from Envoy
            │ :9000 BEAM  │ │ :9000    │        │ ← excluded from Envoy
            └─────────────┘ └──────────┘
```

## Istio-Specific Design Decisions

### Sidecar Injection
The namespace `ai-ha-elixir` has the label `istio-injection: enabled`, so every
pod gets an Envoy sidecar automatically.

### Erlang Distribution Ports Excluded from mTLS
Erlang's native distribution protocol (EPMD on :4369, BEAM on :9000) is a
custom binary protocol. Envoy cannot terminate mTLS for it — traffic would be
corrupted or silently dropped. These ports are excluded via pod annotations:

```yaml
traffic.sidecar.istio.io/excludeInboundPorts: "4369,9000"
traffic.sidecar.istio.io/excludeOutboundPorts: "4369,9000"
```

This means inter-node Erlang clustering bypasses the mesh (plaintext), while
all HTTP traffic between pods and external ingress goes through Envoy with mTLS.

### Gateway + VirtualService (no nginx Ingress)
External traffic enters through an Istio `Gateway` → `VirtualService` chain,
replacing the previous nginx `Ingress`. This gives you:
- Automatic retries (3 attempts, 2s per-try timeout)
- Overall request timeout (15s)
- mTLS from edge to pod

## Files

| File | Purpose |
|---|---|
| `services.yml` | Namespace (with Istio injection), headless + ClusterIP services |
| `statefulset.yml` | App pods with sidecar annotations and Erlang port exclusions |
| `configmap.yml` | Runtime configuration for the Elixir nodes |
| `gateway.yml` | Istio Gateway — terminates external HTTP traffic |
| `virtualservice.yml` | Istio VirtualService — routes to app with resilience policies |
| `db.yml` | PostgreSQL deployment and service |

## Deployment

```bash
# 1. Create namespace and all resources (namespace must come first for injection label)
kubectl apply -f kubernetes/services.yml
kubectl apply -f kubernetes/configmap.yml
kubectl apply -f kubernetes/db.yml
kubectl apply -f kubernetes/statefulset.yml
kubectl apply -f kubernetes/gateway.yml
kubectl apply -f kubernetes/virtualservice.yml

# Or in one shot (works because namespace is first in services.yml):
kubectl apply -R -f kubernetes/

# 2. Set secrets (SECRET_KEY_BASE and AI_TOKEN)
kubectl create secret generic ai-ha-elixir-secrets \
  --from-literal=SECRET_KEY_BASE=$(openssl rand -base64 64) \
  --from-literal=AI_TOKEN="your-token" \
  -n ai-ha-elixir

# 3. Verify pods + sidecars have 2 containers each
kubectl get pods -n ai-ha-elixir
kubectl describe pod <pod-name> -n ai-ha-elixir | grep "Containers:"
```

## Migration Notes (from nginx Ingress)

- The old `ingress.yml` has been removed. If your cluster does not use Istio,
  you can revert to it or create a standard nginx Ingress referencing the same
  service (`ai-ha-elixir`, port 80).
- Set `$INGRESS_HOST` consistently in both `configmap.yml` (PHX_HOST) and the
  Gateway/VirtualService before applying.
