# EZThrottle Local behind a Gateway API proxy (Envoy Gateway)

Ported from [Aquifer's identical example](https://github.com/rjpruitt16/aquifer/tree/main/examples/kubernetes) --
EZThrottle Local as a normal Deployment, reached through a [Gateway API](https://gateway.k8s.io/)
proxy instead of a sidecar. The Gateway owns routing, TLS termination, and the cluster's single
ingress point; EZThrottle Local owns the queue behind it -- not a way to horizontally scale it itself.

Tested against **Gateway API v1.6.0** and **Envoy Gateway v1.9.0** (current stable as of writing,
same versions Aquifer's example was verified against). Pin your own cluster to a specific release
rather than "latest" -- both projects ship frequently.

## Why `replicas: 1`

This is not a simplification to loosen later. EZThrottle Local's durable queue is Mnesia
`disc_copies` backed by a local `MNESIA_DIR` per instance, and pool membership plus the SSE/PubSub
subscriber state are in-process (BEAM) only in this deployment shape. Scaling is by
**partitioning** -- running one instance per upstream domain or tenant -- not by adding replicas
behind one Service. Multiple replicas sharing this manifest's `Service` would risk double-dispatch
on retries and would make pool members registered on one replica invisible to another. If you need
more capacity, deploy a second, separately partitioned copy of this example (different namespace,
own PVC, own `HTTPRoute` path or hostname), not a higher `replicas` count.

## Two real gotchas found while verifying this example

Not simplifications or defensive boilerplate -- both caused a hard boot failure in testing and are
fixed in `deployment.yaml` as shipped:

1. **Stable node naming (`RELEASE_NODE`), required.** `rel/env.sh.eex` names the Erlang node after
   `$(hostname)` by default, which is the Pod's own name -- new on every single restart under a
   Deployment. Mnesia's `disc_copies` schema is tied to the exact node name that created it, so
   without a fixed name, any pod restart makes Mnesia treat its own on-disk data as belonging to a
   node that no longer exists and fails to boot (`node_not_running`). Same class of bug already hit
   and fixed for Fly.io (see the comment in `rel/env.sh.eex`); this is the Kubernetes equivalent.
2. **No `resources.limits.memory`, deliberately.** Confirmed in testing (`kind` on Docker Desktop)
   that setting one -- at 512Mi *and* at 1Gi -- causes an instant `OOMKilled` (exit 137) on every
   boot attempt, despite the same image using ~136MiB under plain `docker run -m 512m`. A CPU limit
   alone is unaffected. This looked like a BEAM/cgroup memory-detection mismatch specific to that
   environment, not a real memory requirement -- test carefully in your own cluster before adding a
   memory limit back, and use the app's own `EZTHROTTLE_MEMORY_LIMIT_MB` admission-control setting
   for a safety net instead.

## Prerequisites

- A Kubernetes cluster (Aquifer's version of this example was verified end-to-end against a local
  [`kind`](https://kind.sigs.k8s.io/) cluster -- `kind create cluster` is the fastest way to try
  this yourself)
- [Envoy Gateway](https://gateway.envoyproxy.io/docs/install/) installed in-cluster (v1.9.0+) via
  Helm:
  ```bash
  helm install eg oci://docker.io/envoyproxy/gateway-helm --version v1.9.0 \
    -n envoy-gateway-system --create-namespace
  kubectl wait --timeout=180s -n envoy-gateway-system deployment/envoy-gateway --for=condition=Available
  ```
  **Don't install the Gateway API CRDs separately first.** Envoy Gateway's Helm chart bundles its
  own copy and installs them via server-side apply -- applying the standalone
  [Gateway API release manifest](https://github.com/kubernetes-sigs/gateway-api/releases) first (via
  plain `kubectl apply`, which uses client-side apply) causes a field-manager conflict and the Helm
  install fails outright. Let the chart provide the CRDs. Confirmed no default `GatewayClass` ships
  with the chart -- `gatewayclass.yaml` below is required, not optional.
- A `ReadWriteOnce`-capable `StorageClass` available in your cluster (`kind` provides one by default)
- A container image built from this repo's `Dockerfile` and pushed somewhere your cluster can pull
  from. Unlike Aquifer, this repo doesn't currently publish one to a registry (deploys are via
  `fly deploy`'s local build, not a pushed image) -- build and push your own:
  ```bash
  docker build -t your-registry/ezthrottle-local:latest .
  docker push your-registry/ezthrottle-local:latest
  ```
  then update `image:` in `deployment.yaml` to match.
- A `SECRET_KEY_BASE`, generated locally and created as a cluster Secret -- `runtime.exs` raises on
  boot in prod without one, same as a bare `mix phx.gen.release` deploy would:
  ```bash
  kubectl create namespace ezthrottle-local --dry-run=client -o yaml | kubectl apply -f -
  kubectl create secret generic ezthrottle-local-secret \
    --from-literal=secret-key-base="$(mix phx.gen.secret)" \
    -n ezthrottle-local
  ```
  (Not committed to `kustomization.yaml` on purpose -- generate and apply this yourself rather than
  reusing a value out of a Git repo.)

## Deploy

```bash
kubectl apply -k .
```

This creates the `ezthrottle-local` namespace (if the Secret step above didn't already), a 1Gi PVC,
a single-replica Deployment, a `ClusterIP` Service, and the Gateway API resources (`GatewayClass`,
`Gateway`, `HTTPRoute`) routing all traffic to it.

## Verify

```bash
kubectl get pods -n ezthrottle-local
kubectl get httproute -n ezthrottle-local ezthrottle-local -o jsonpath='{.status.parents[0].conditions}'
```

The `HTTPRoute` status conditions should show `Accepted` and `ResolvedRefs` once Envoy Gateway has
picked it up. Find the Envoy proxy Service Envoy Gateway provisions for this Gateway
(`kubectl get svc -n envoy-gateway-system | grep ezthrottle-local-gateway`) and confirm `GET /health`
responds through it, then submit a real job through `POST /jobs` on the same address and confirm it
reaches `"status": "completed"`.

**Verified end-to-end** against a local `kind` cluster with Gateway API v1.6.0 and Envoy Gateway
v1.9.0: `HTTPRoute` came up `Accepted`/`ResolvedRefs`, `GET /health` returned 200 through the Envoy
proxy, a real job (`POST /jobs` → `postman-echo.com`) returned 201 with a job ID, and polling
`GET /jobs/:id` afterward showed `"status": "completed"`. Also verified the specific thing that
makes this deployment shape different from Aquifer's SQLite-backed one: deleted the running pod
mid-test to force a real restart onto a new hostname, and confirmed the job created before the
restart was still readable afterward -- Mnesia durability surviving a pod restart, not just a
process restart on the same machine. That only works because of the `RELEASE_NODE` fix documented
in `deployment.yaml` below; without it, the second pod failed to boot at all.

## Customizing

- **Image**: see the Prerequisites section above -- there's no published image to pin a tag on yet,
  unlike Aquifer.
- **Sizing**: the CPU/memory requests in `deployment.yaml` are a starting point, not a benchmarked
  recommendation -- see the root [benchmark.md](../../benchmark.md) and the README's "For maximum
  queue capacity" guidance before sizing for real traffic.
- **TLS**: this example is HTTP-only on the Gateway listener, to keep the example focused on the
  Gateway API wiring itself. A production deployment would add an HTTPS listener with a cert (e.g.
  via [cert-manager](https://cert-manager.io/)) -- not included here.
