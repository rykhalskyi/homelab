---
tags: [ragatool, talos, flux, gitops, ghcr, rag, mcp, lan, deploy, wiki]
date: 2026-10-28
source_count: 0
---

# Ragatool on Talos (LAN-only RAG + MCP)

**Ragatool** is a local RAG knowledge base (FastAPI + Angular) with embedded MCP
servers. It runs on the `talos` cluster as two Flux-managed Deployments in
namespace **`ragatool`**, stores all state on a single `local-path` PVC, and is
reachable **only from the LAN** at the `*.homelab.home.arpa` names below. It is
never routed through the `*.otakeessen.com` Cloudflare tunnel.

> Status: manifests and workflow prepared; not yet deployed. The images must be
> rebuilt once (see [Image build](#image-build)) because the "runtime config"
> frontend change is new.

## Picture

```
GitHub rykhalskyi/ragatool ──Create Package──► ghcr.io/rykhalskyi/ragatool-{backend,frontend}:sha-<sha>
         │                                                   │
         └────────────── repository_dispatch ────────────────┘
                                │
GitHub rykhalskyi/homelab ◄── pin PR ──┘
        │
        │ Flux (talos `apps` Kustomization)
        ▼
  ragatool namespace
   ├─ ragatool-frontend (nginx, :80)  ◄── Ingress ── Traefik VIP 192.168.2.240
   │     └─ /api/ reverse proxy ──► ragatool-backend:8000
   └─ ragatool-backend  (:8000 REST/SSE, :8001 MCP-SSE, :8002 MCP-HTTP)
         └─ /data (10Gi PVC): SQLite + Chroma + fastembed model cache
```

## LAN hostnames

All hosts resolve to Traefik's LoadBalancer VIP `192.168.2.240`; add them to a
client `/etc/hosts` (or to Pi-hole/local DNS) — there is no public DNS or
Cloudflare route.

| Host | Target | Purpose |
|------|--------|---------|
| `ragatool.homelab.home.arpa` | `ragatool-frontend:80`, `/mcp` → `ragatool-backend:8002` | Angular UI; `/api/` proxied to the backend; `/mcp` is the streamable-HTTP MCP endpoint |
| `ragatool-mcp.homelab.home.arpa` | `ragatool-backend:8001` | MCP over SSE (`/mcp`) |
| `ragatool-mcp-http.homelab.home.arpa` | `ragatool-backend:8002` | Optional alternative MCP HTTP host (`/mcp`) |

```text
192.168.2.240 ragatool.homelab.home.arpa
192.168.2.240 ragatool-mcp.homelab.home.arpa
192.168.2.240 ragatool-mcp-http.homelab.home.arpa
```

The UI host is enough for opencode: the same host routes `/mcp` to the backend
(see `ingress.yaml`), so no extra DNS record is needed for HTTP MCP.

> There is no authentication in Ragatool yet. That is why it is LAN-only; do not
> add a `*.otakeessen.com` Ingress until auth exists.

## Runtime frontend configuration (no rebuild per deployment)

The Angular app used to bake `apiUrl` into the bundle at build time (the released
GHCR image pointed at `http://localhost:4301`). The frontend now resolves the API
address **at container start**:

- `frontend/public/config.js` is loaded before the Angular bundle and exposes
  `window.RAGATOUL_CONFIG.apiUrl`.
- `frontend/docker-entrypoint.d/40-write-runtime-config.sh` overwrites that file
  from `API_URL` before nginx starts (default `/api`).
- `frontend/nginx.conf.template` is rendered by the nginx image's `envsubst`
  entrypoint; it proxies `location /api/` to `${BACKEND_URL}` (default
  `http://backend:8000`), with buffering disabled so `/logs/stream` SSE works.
- `src/environments/runtime-config.ts` returns the runtime value when present,
  otherwise the build-time `environment.apiUrl` (for `ng serve`).

The homelab ConfigMap supplies:

```yaml
API_URL: "/api"
BACKEND_URL: "http://ragatool-backend.ragatool.svc.cluster.local:8000"
```

So the same image can be moved to another host/namespace without rebuilding:
change `API_URL` and/or `BACKEND_URL` in `ragatool-frontend-config`.

## The pieces

| File | Role |
|------|------|
| `infra/clusters/talos/apps/ragatool/namespace.yaml` | `Namespace/ragatool` |
| `infra/clusters/talos/apps/ragatool/pvc.yaml` | `ragatool-data`, 10Gi `local-path` (SQLite + Chroma + models) |
| `infra/clusters/talos/apps/ragatool/configmap-backend.yaml` | embedding/rerank models, cache dir, MCP bind addresses, CORS origin |
| `infra/clusters/talos/apps/ragatool/configmap-frontend.yaml` | `API_URL`, `BACKEND_URL` |
| `infra/clusters/talos/apps/ragatool/deployment-backend.yaml` | FastAPI + MCP; `workingDir: /data`, `uvicorn --app-dir /app`; pinned image |
| `infra/clusters/talos/apps/ragatool/deployment-frontend.yaml` | nginx UI + `/api` proxy; pinned image |
| `.../service-backend.yaml` | ClusterIP ports 8000 / 8001 / 8002 |
| `.../service-frontend.yaml` | ClusterIP port 80 |
| `.../ingress.yaml` | UI host → frontend |
| `.../ingress-mcp-sse.yaml` | MCP SSE host → backend 8001 |
| `.../ingress-mcp-http.yaml` | MCP HTTP host → backend 8002 |
| `.github/workflows/update-ragatool-image-pin.yml` | pins both images by digest in a PR |

No Secret is required: Ragatool uses local embeddings/reranker models and has no
API keys or login.

## State and persistence

The backend image keeps its code in `/app`, but the container runs with working
directory `/data`. The app's relative paths therefore persist on the PVC:

| Path | Contents |
|------|----------|
| `/data/ragatouille.db` | SQLite: collections, settings, task history |
| `/data/chroma_data` | Chroma vector store |
| `/data/fastembed` | downloaded embedding/reranker models (`FASTEMBED_CACHE_DIR`) |
| `/data/huggingface` | HuggingFace/Xet cache + logs (`HF_HOME`; `HOME` is `/data` too) |

Models are downloaded **on first use**, not at startup, so the Pod needs outbound
internet the first time a collection is embedded or a query is reranked. After
that the cache is local.

The PVC is `local-path` and the Deployment uses `strategy: Recreate` (RWO). There
is no HA and no built-in backup yet; copy `/data` or add a restic CronJob if the
knowledge base becomes important (see
[[File-volume backups on Talos (restic → MinIO) — plan]]).

## Image build

The two images are built together by the ragatool repo's **Actions → Create
Package → Run workflow** on `main`. The workflow pushes
`ghcr.io/rykhalskyi/ragatool-{backend,frontend}:sha-<commit>` (plus `latest`) and,
when the repo has a `HOMELAB_DISPATCH_TOKEN` Actions secret, sends a
`ragatool-images` `repository_dispatch` to `rykhalskyi/homelab`.

`update-ragatool-image-pin.yml` resolves both digests and opens a
`bot/ragatool-images-<short>` PR that rewrites both `image:` lines to
`sha-<commit>@sha256:<digest>`. Merge it and Flux rolls the Pods. Without the
dispatch token, trigger it manually:

```bash
gh workflow run update-ragatool-image-pin.yml -f sha=<ragatool-commit>
```

The GHCR packages must be public (or add an image pull secret).

### Which build is running?

```bash
kubectl --context talos -n ragatool get deploy -o wide
kubectl --context talos -n ragatool get deploy ragatool-backend \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
docker buildx imagetools inspect ghcr.io/rykhalskyi/ragatool-backend:sha-<commit>
```

## Deploy

There are no secrets to apply. First-time order matters because the manifests
must exist on `main` before the pin workflow can edit them:

1. Merge the manifests PR (this namespace/stack; it starts with bootstrap
   `latest` digests, so the UI will not work until step 3).
2. In `rykhalskyi/ragatool`, run **Create Package** on the commit with the
   runtime-config frontend.
3. Merge the auto-opened image-pin PR.
4. Flux reconciles; the backend initialises SQLite/Chroma on the PVC and starts
   the two MCP listeners.

```bash
flux reconcile kustomization apps -n flux-system --context talos --with-source
kubectl --context talos -n ragatool rollout status deploy/ragatool-backend
kubectl --context talos -n ragatool rollout status deploy/ragatool-frontend
```

## Verify

```bash
kubectl --context talos -n ragatool get pods,svc,ingress,pvc
kubectl --context talos -n ragatool logs deploy/ragatool-backend | tail -30

curl -s http://ragatool.homelab.home.arpa/api/version
curl -s http://ragatool.homelab.home.arpa/config.js
curl -sI http://ragatool-mcp-http.homelab.home.arpa/mcp
```

Then open `http://ragatool.homelab.home.arpa/`, create a collection, and import a
small document to confirm embedding works (this triggers the first model
download).

## MCP clients

Point an agent at either transport:

```jsonc
// streamable HTTP (opencode etc.) -- no extra DNS record needed
"Ragatool": { "url": "http://ragatool.homelab.home.arpa/mcp" }

// alternative HTTP host, if you created its DNS record
"Ragatool": { "url": "http://ragatool-mcp-http.homelab.home.arpa/mcp" }

// SSE (requires the ragatool-mcp DNS record)
"Ragatool": { "url": "http://ragatool-mcp.homelab.home.arpa/mcp" }
```

The client must be on the LAN and able to resolve the hostname (or use the
`192.168.2.240` IP with a Host header). MCP servers are exposed without auth, so
keep them LAN-only.

## Updating

1. Merge the change in `rykhalskyi/ragatool`.
2. Run **Create Package** (or let the dispatch arrive) → new `sha-<commit>` images.
3. Merge the pin PR.
4. Flux rolls the Deployments; SQLite migrations/CREATE TABLE run on backend
   startup and the PVC is preserved.

## Troubleshooting

- **UI loads but every request fails / calls `localhost:4301`.** The frontend
  image is still the old build-time-config image. Rebuild it and merge the pin
  PR; confirm `curl http://ragatool.homelab.home.arpa/config.js` shows
  `{ apiUrl: "/api" }`.
- **Frontend CrashLoopBackOff with `host not found in upstream`.** `BACKEND_URL`
  points at a hostname nginx cannot resolve at startup. Fix
  `ragatool-frontend-config` (the k8s value is
  `http://ragatool-backend.ragatool.svc.cluster.local:8000`).
- **First embedding/rerank request fails with `Permission denied (os error 13)`
  writing `/.cache/huggingface/xet/logs/...`.** The container runs as UID 1000
  with no home directory, so `huggingface_hub`/Xet tried to use `/.cache`. The
  ConfigMap sets `HOME=/data` and `HF_HOME=/data/huggingface`; recreate the Pod
  after changing it, and remove the partial
  `/data/fastembed/models--qdrant--bge-small-en-v1.5-onnx-q` directory so the
  download starts clean.
- **First embedding/rerank request hangs or fails.** The Pod cannot reach the
  model host, or the cache path is not writable. Check
  `kubectl logs deploy/ragatool-backend` and that `/data/fastembed` exists.
- **`/logs/stream` does not stream.** The nginx proxy must keep
  `proxy_buffering off` for the `/api/` location; it is already in the template.
- **MCP 404.** Use `/mcp` on the MCP hosts, and the right transport: SSE host →
  8001, HTTP host → 8002.
- **Pod stuck Pending.** The 10Gi `local-path` PVC cannot be satisfied on the
  node (disk full) — check `kubectl -n ragatool describe pvc ragatool-data`.

## Rollback

```bash
flux suspend kustomization apps -n flux-system --context talos
kubectl --context talos -n ragatool scale deploy/ragatool-backend --replicas=0
kubectl --context talos -n ragatool scale deploy/ragatool-frontend --replicas=0
```

Re-pin the previous digests (revert the pin PR) and `flux resume`. The PVC and
its data are untouched, so this is lossless.
