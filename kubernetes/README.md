# Kubernetes Deployment with Gateway API

This directory contains the Kubernetes manifests for deploying elixirAI using the **standard Kubernetes Gateway API** (`HTTPRoute`). The Erlang distribution ports are excluded from mesh sidecar interception so clustering remains healthy.

## Architecture

```
                         ┌───────────────┐
  $INGRESS_HOST ─────────▶│   Gateway     │
  (e.g. ai.example.com)   │ (standard)    │
                          └───────┬───────┘
                                  │ HTTP/80
                          ┌───────▼───────┐
                          │   HTTPRoute   │──→ routes to ClusterIP service
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
            │ │ Envoy   │ │ │ │Envoy  ││        │
            └─────────┘ │ │ └───────┘│        │
            │ :4369 EPMD  │ │ :4369    │        ← excluded from Envoy
            │ :9000 BEAM  │ │ :9000    │        ← excluded from Envoy
            └─────────────┘ └──────────┘
```

## Gateway API Design Decisions

### HTTPRoute Instead of Ingress or VirtualService
External traffic enters through a standard Kubernetes **Gateway** → **HTTPRoute**
chain. This is the portable, upstream-recommended approach that works with any
Gateway API-compliant controller (Istio, GCE, AWS LB, nginx, etc.) without
vendor-specific resources.

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

## Files

| File | Purpose |
|---|---|
| `services.yml` | Namespace (with Istio injection), headless + ClusterIP services |
| `statefulset.yml` | App pods with sidecar annotations and Erlang port exclusions |
| `configmap.yml` | Runtime configuration for the Elixir nodes |
| `httproute.yml` | HTTPRoute — routes external traffic to the app service via a standard Gateway API controller |
| `ingress.yml` | Fallback nginx Ingress (for clusters without a Gateway API controller) |
| `db.yml` | PostgreSQL deployment and service |

## Deployment

```bash
# 1. Ensure a Gateway resource exists in your cluster (or create one).
#    The HTTPRoute references it by name — update httproute.yml accordingly.

# 2. Create namespace and all resources (namespace must come first for injection label)
kubectl apply -f kubernetes/services.yml
kubectl apply -f kubernetes/configmap.yml
kubectl apply -f kubernetes/db.yml
kubectl apply -f kubernetes/statefulset.yml
kubectl apply -f kubernetes/httproute.yml

# Or in one shot (works because namespace is first in services.yml):
kubectl apply -R -f kubernetes/

# 3. Set secrets (SECRET_KEY_BASE and AI_TOKEN)
kubectl create secret generic ai-ha-elixir-secrets \
  --from-literal=SECRET_KEY_BASE=$(openssl rand -base64 64) \
  --from-literal=AI_TOKEN="your-token" \
  -n ai-ha-elixir

# 4. Verify pods + sidecars have 2 containers each
kubectl get pods -n ai-ha-elixir
kubectl describe pod <pod-name> -n ai-ha-elixir | grep "Containers:"
```

## Migration Notes (from nginx Ingress)

- The old `ingress.yml` is retained as a **fallback** for clusters without a
  Gateway API controller. Use `httproute.yml` by default when available.
- Set `$INGRESS_HOST` consistently in both `configmap.yml` (PHX_HOST) and the
  HTTPRoute before applying.
- Ensure your cluster has a **Gateway** resource that matches the `parentRef`
  name in `httproute.yml`. Update it if your existing Gateway has a different
  name.
