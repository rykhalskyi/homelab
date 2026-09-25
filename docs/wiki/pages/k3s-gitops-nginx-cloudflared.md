---
tags: [k3s, kubernetes, gitops, flux, nginx, cloudflared, traefik, ghcr, ci]
date: 2026-09-25
source_count: 0
---

# k3s + GitOps: nginx and cloudflared (phase 2.1)

A plain-language, step-by-step guide for moving the homelab website
(`infra/nginx`) and the Cloudflare tunnel off Docker Compose + a host systemd
service, and onto a **k3s** cluster where **Flux** keeps everything in sync with
this Git repository.

No prior Kubernetes knowledge is assumed. Every hard word is explained.

## The idea in one picture

```
  You edit Git  ──push──►  GitHub (rykhalskyi/homelab)
                                    │
                                    │  Flux watches the repo
                                    ▼
  ┌─────────────────────────── k3s cluster (node-one) ───────────────────────────┐
  │                                                                              │
  │   Flux  ──►  Traefik  (the traffic director / Ingress)                        │
  │                ▲                                                             │
  │                │ http://traefik.traefik.svc.cluster.local:80                 │
  │                │                                                             │
  │   cloudflared Pod  ◄───  the Cloudflare tunnel (public side)                 │
  │                                                                              │
  │   nginx Pod  (the website HTML, baked into an image)                          │
  └──────────────────────────────────────────────────────────────────────────────┘
                                    ▲
  Internet  ──►  https://homelab.otakeessen.com  ──►  Cloudflare edge  ──►  tunnel
```

The important change: **you stop running commands on the server to deploy**.
You change files in Git; Flux notices and makes the cluster match.

## Tiny glossary

| Word | What it means here |
|------|--------------------|
| **Pod** | One running copy of a container (like one `docker run`) inside the cluster. |
| **Deployment** | A manager that keeps N Pods running and rolls out updates. "I want 1 nginx always running." |
| **Service** | A stable internal name/address for a set of Pods. Other Pods reach nginx at the name `nginx`. |
| **Namespace** | A folder for cluster objects. We put ours in `homelab` to keep them tidy. |
| **Ingress** | A routing rule: "requests for this hostname go to this Service." |
| **Traefik** | The software that reads Ingress rules and routes traffic. |
| **Flux** | The GitOps robot inside the cluster: it watches Git and applies changes. |
| **HelmRelease** | A Flux object that installs a packaged app (here: Traefik) from a Helm chart. |
| **kustomization.yaml** | A plain list saying "these YAML files belong together." |
| **GHCR** | GitHub Container Registry — where we store the website's container image. |

## What stays the same

- The website HTML/CSS/JS and the generated wiki. Nothing about the site changes.
- The domain `otakeessen.com`, the Cloudflare tunnel, and the public hostname
  `homelab.otakeessen.com`.
- The wiki workflow (`docs/wiki/` → `make wiki`).

## What you need before starting

- SSH access to `node-one` with `sudo`.
- `otakeessen.com` already active in Cloudflare (it is).
- The existing tunnel credentials at `~/.cloudflared/<UUID>.json` on `node-one`
  (created in [[Cloudflare Tunnel → nginx (install + first tunnel)]]).
- A workstation with `kubectl` and the `flux` CLI installed.
- This repo cloned on the workstation, with push access to `main`.
- The GHCR package made **public** at the end of Part A (or the cluster needs a
  pull secret).

### Install `kubectl` on the workstation (Fedora)

```bash
KVER=$(curl -Ls https://dl.k8s.io/release/stable.txt)
curl -LO "https://dl.k8s.io/release/${KVER}/bin/linux/amd64/kubectl"
sudo install -m 0755 kubectl /usr/local/bin/kubectl
kubectl version --client
```

`sudo dnf install kubernetes-client` also works but usually ships an older
version. Keep `kubectl` within one minor version of the server. Configuring it
means giving it a kubeconfig (Part B3); there is no separate setup command. The
`flux` CLI is installed in Part C0.

> Do the parts in order. Parts A and B are independent; C must come after B, and
> E/F after D.

## Where to run commands (workstation vs server)

Rule of thumb: **use the cluster from your workstation; SSH to node-one only for
the host itself.**

| Task | Run it on |
|------|-----------|
| `git push`, `flux bootstrap`, `flux reconcile` | workstation |
| `kubectl get/describe/logs/port-forward`, k9s | workstation |
| install/upgrade k3s, edit `/etc/rancher/k3s/config.yaml`, `systemctl` | server (SSH) |
| disk/network checks, rescue when the API is down, the first kubeconfig copy | server (SSH) |

Why: `kubectl` and `flux` are just clients, so they work over the LAN. GitOps
means changes flow from Git, not from an interactive shell on the server, so
editing objects with `kubectl edit` is avoided. SSH is kept for what Kubernetes
cannot do: install, host configuration, and recovery.

Two safety notes:

- Keep the API server (port `6443`) on the LAN, not the public internet. To avoid
  exposing it at all, tunnel it: `ssh -L 6443:127.0.0.1:6443 jaro@192.168.2.233`
  and set the kubeconfig `server:` to `https://127.0.0.1:6443`.
- The k3s kubeconfig is `cluster-admin` (full power). Treat it like a password:
  never commit it and never paste it anywhere public.

---

## Part A — Build the website into a container image

**Why:** Kubernetes has no bind mounts, so we cannot mount `./html` from the
repo like Compose did. Instead we bake the site into an image and the Pod runs
that image.

### A1. Create `infra/nginx/Dockerfile`

```dockerfile
FROM nginx:stable
COPY conf.d/ /etc/nginx/conf.d/
COPY html/ /usr/share/nginx/html/
```

### A2. Create `infra/nginx/.dockerignore`

```
README.md
docker-compose.yml
```

### A3. Create `.github/workflows/build-nginx-image.yml`

This builds and uploads the image every time the site or the wiki changes.

```yaml
name: Build nginx site image

on:
  push:
    branches: [main]
    paths:
      - 'infra/nginx/**'
      - 'docs/wiki/**'
      - 'tools/build_wiki.py'
      - '.github/workflows/build-nginx-image.yml'
  workflow_dispatch:

permissions:
  contents: read
  packages: write

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Check the generated wiki is up to date
        run: |
          make wiki
          git diff --exit-code

      - name: Log in to GHCR
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Build and push
        id: build
        uses: docker/build-push-action@v6
        with:
          context: infra/nginx
          push: true
          tags: ghcr.io/${{ github.repository_owner }}/homelab-nginx:sha-${{ github.sha }}

      - name: Show the digest to pin
        run: |
          echo "Pin this digest: ${{ steps.build.outputs.digest }}"
```

> **`secrets.GITHUB_TOKEN` is automatic - do not create it.** GitHub injects it
> into every Actions run. The workflow's `permissions: packages: write` is what
> lets it push to GHCR. If the push is denied, set **Settings -> Actions ->
> General -> Workflow permissions** to "Read and write permissions" and re-run.

### A4. Build it

```bash
cd ~/Source/homelab
git add infra/nginx/Dockerfile infra/nginx/.dockerignore \
        .github/workflows/build-nginx-image.yml
git commit -m "Build nginx site image in CI"
git push
```

Open the **Actions** tab, wait for the run to finish, and copy the
`sha256:...` digest printed in the last step.

### A5. Make the package public

GitHub → your profile → **Packages** → `homelab-nginx` → **Package settings** →
**Change visibility** → **Public**. (If you skip this, the cluster needs an
image pull secret — simpler to make it public.)

> **Verify:** the Actions run is green and the package exists.

---

## Part B — Install k3s

**Why:** k3s is a small, single-binary Kubernetes. We install it *without* its
bundled Traefik, because we install and manage Traefik ourselves in Part D (so
k3s and the future Talos cluster look the same).

### B1. Tell k3s to skip Traefik

On `node-one`, create `/etc/rancher/k3s/config.yaml`:

```yaml
disable:
  - traefik
write-kubeconfig-mode: "0644"
```

### B2. Install k3s

```bash
curl -sfL https://get.k3s.io | sh -
sudo systemctl status k3s --no-pager
kubectl get nodes
```

### B3. Let your workstation talk to the cluster (kubeconfig)

`kubectl` and `flux` both find the cluster through a **kubeconfig** file. It
holds two things: the API server's address (for k3s, port `6443`) and the
credentials to log in. Nothing in Flux needs node-one's IP directly — only this
file does.

On the server the file is `/etc/rancher/k3s/k3s.yaml` and its address is
`https://127.0.0.1:6443`. Copy it to your workstation and swap the loopback
address for node-one's LAN IP:

```bash
mkdir -p ~/.kube
ssh jaro@192.168.2.233 'sudo cat /etc/rancher/k3s/k3s.yaml' > ~/.kube/config
chmod 600 ~/.kube/config
sed -i 's/127.0.0.1/192.168.2.233/' ~/.kube/config
kubectl config get-contexts
kubectl get nodes
```

The part that answers "where is node-one" is the `server:` line:

```yaml
clusters:
  - cluster:
      server: https://192.168.2.233:6443
```

That is the whole configuration. `flux` and `kubectl` read this file from the
`KUBECONFIG` environment variable (default `~/.kube/config`). Once
`kubectl get nodes` works, `flux bootstrap` can reach the cluster too. For a
second cluster (Talos) you get a second kubeconfig and pick between them with
contexts (`kubectl config use-context`, or `KUBECONFIG=... flux bootstrap ...`).

On the server itself, the `kubectl` bundled with k3s already knows this path, so
`k3s kubectl get pods -A` (or plain `kubectl`) just works. Upstream tools like
`helm` may need `KUBECONFIG=/etc/rancher/k3s/k3s.yaml` or
`--kubeconfig /etc/rancher/k3s/k3s.yaml`.

> **Two kubeconfig files - do not mix them up.** k3s writes one on the server at
> `/etc/rancher/k3s/k3s.yaml` (address `https://127.0.0.1:6443`). You create a
> second copy on your workstation at `~/.kube/config`, and edit its address to
> node-one's LAN IP. The `flux` CLI runs on the workstation, so it reads the
> **workstation** copy - that is exactly where it gets the address. Once Flux is
> installed, its Pods do not use either file: they authenticate from inside the
> cluster with their own service account. The kubeconfig contains credentials,
> so it is never committed to Git; Git holds desired state, not connection info.

> **This file grants unrestricted access.** It authenticates as `system:admin`
> (group `system:masters`), which Kubernetes hardcodes to full power over the
> cluster. Treat it like a password.

> **A copied kubeconfig goes stale.** k3s refreshes the certificates inside
> `/etc/rancher/k3s/k3s.yaml` every time it starts, but it does **not** update
> your copy. If `kubectl` later fails with a certificate error, re-copy the file
> and re-apply the `sed` above. See the official
> [k3s cluster access docs](https://docs.k3s.io/cluster-access).

> **Verify:** `kubectl get nodes` shows `node-one` in `Ready`.

---

## Part C — Install Flux (the GitOps robot)

**This is the one manual step in the whole guide.** Everything else is applied
by Flux from Git; this part is the seed that starts Flux running.

> **Who installs the installer?** Something has to put the first Git-watcher
> into the cluster. That is you, once, by running `flux bootstrap`. After this,
> Flux reads Git and does the rest, including keeping itself updated. You never
> run bootstrap again for this cluster.

There are two separate things both called "Flux" — keep them apart:

| Thing | Where it lives | How often |
|-------|----------------|-----------|
| the `flux` **CLI** (a binary, like `kubectl`) | your workstation | once per workstation |
| the Flux **controllers** (Pods) | inside the cluster, in `flux-system` | once per cluster, by `flux bootstrap` |

### C0. Install the `flux` CLI on your workstation

```bash
curl -s https://fluxcd.io/install.sh | sudo bash
flux --version
```

(This is the only thing installed on your laptop. It is a thin client: it does
not need Docker and it does not stay running.)

### C1. Bootstrap Flux against this repo

Run this **on your workstation**, with your kubeconfig pointing at the cluster
you want to install into. The command talks to the cluster with that kubeconfig
and to GitHub with `GITHUB_TOKEN`, then exits.

```bash
export GITHUB_TOKEN=ghp_your_token_with_repo_scope

flux bootstrap github \
  --owner=rykhalskyi \
  --repository=homelab \
  --branch=main \
  --path=infra/k8s/clusters/node-one \
  --personal
```

> **This `GITHUB_TOKEN` is different from the workflow's.** It is a Personal
> Access Token you create yourself: GitHub -> **Settings -> Developer settings ->
> Personal access tokens**. A classic token with the **`repo`** scope is enough
> (a fine-grained token needs `Contents: Read/Write` and `Administration:
> Read/Write` on `homelab`). The `flux` CLI uses it once for bootstrap; keep it
> out of Git and delete/rotate it afterwards. The `secrets.GITHUB_TOKEN` in Part
> A is separate and automatic.

This installs the Flux controllers into the cluster and commits a
`flux-system/` folder under `infra/k8s/clusters/node-one/` that tells those
controllers where to sync from. You can confirm the Pods exist with
`kubectl -n flux-system get deploy,rs,pods`.

> **Where you run it from does not matter.** Bootstrap talks to the remote repo
> (via `GITHUB_TOKEN`) and to the cluster (via kubeconfig); it does not use your
> local checkout. Run it from anywhere. Afterwards, `git pull` in your clone to
> get the new `flux-system/` files.

> **k3s or Talos — same command.** `flux bootstrap github` does not care which
> distribution runs the cluster. Only two things change: your kubeconfig must
> point at the target cluster, and `--path` names the folder for that cluster
> (for example `--path=infra/k8s/clusters/talos`). Everything under
> `infra/k8s/apps/` and `infra/k8s/infrastructure/` is reused unchanged.

### C2. Verify

```bash
flux check
flux get kustomizations -A
```

> **Verify:** `flux-system` Kustomization is `Ready: True`.

---

## Part D — Traefik (the traffic director)

**Why:** one place decides which hostname reaches which service. Adding
Nextcloud or Forgejo later is just one more Ingress — the tunnel config never
changes.

### D1. Create `infra/k8s/infrastructure/sources/traefik.yaml`

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: traefik
  namespace: flux-system
spec:
  interval: 1h
  url: https://traefik.github.io/charts
```

### D2. Create `infra/k8s/infrastructure/traefik/namespace.yaml`

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: traefik
```

### D3. Create `infra/k8s/infrastructure/traefik/helmrelease.yaml`

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: traefik
  namespace: traefik
spec:
  interval: 1h
  chart:
    spec:
      chart: traefik
      version: ">=30.0.0"
      sourceRef:
        kind: HelmRepository
        name: traefik
        namespace: flux-system
  values:
    service:
      type: LoadBalancer
```

### D4. Create `infra/k8s/infrastructure/kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - sources/traefik.yaml
  - traefik/namespace.yaml
  - traefik/helmrelease.yaml
```

### D5. Create the Flux sync for infrastructure

`infra/k8s/clusters/node-one/infrastructure.yaml`:

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: infrastructure
  namespace: flux-system
spec:
  interval: 10m
  path: ./infra/k8s/infrastructure
  prune: true
  wait: true
  sourceRef:
    kind: GitRepository
    name: flux-system
```

### D6. Push and verify

```bash
git add infra/k8s
git commit -m "Add Traefik via Flux"
git push
flux get kustomizations -A
kubectl -n traefik get pods,svc
```

> **Verify:** Traefik Pod is `Running` and its Service has an external IP
> (k3s ServiceLB assigns one).

---

## Part E — nginx (the website)

### E1. Create `infra/k8s/apps/namespace.yaml`

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: homelab
```

### E2. Create `infra/k8s/apps/nginx/deployment.yaml`

Replace `sha-XXXX` and `sha256:YYYY` with the tag and digest from Part A.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx
  namespace: homelab
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      containers:
        - name: nginx
          image: ghcr.io/rykhalskyi/homelab-nginx:sha-XXXX@sha256:YYYY
          ports:
            - containerPort: 80
          readinessProbe:
            httpGet:
              path: /
              port: 80
          resources:
            requests:
              cpu: 10m
              memory: 16Mi
            limits:
              memory: 64Mi
```

### E3. Create `infra/k8s/apps/nginx/service.yaml`

```yaml
apiVersion: v1
kind: Service
metadata:
  name: nginx
  namespace: homelab
spec:
  selector:
    app: nginx
  ports:
    - port: 80
      targetPort: 80
```

### E4. Create `infra/k8s/apps/nginx/ingress.yaml`

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: nginx
  namespace: homelab
spec:
  ingressClassName: traefik
  rules:
    - host: homelab.otakeessen.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: nginx
                port:
                  number: 80
```

### E5. Create `infra/k8s/apps/nginx/kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
  - service.yaml
  - ingress.yaml
```

### E6. Create `infra/k8s/apps/kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - nginx
  - cloudflared
```

(The `cloudflared` entry will exist after Part F. If you push before Part F,
leave it out for now.)

### E7. Create the Flux sync for apps

`infra/k8s/clusters/node-one/apps.yaml`:

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: apps
  namespace: flux-system
spec:
  interval: 10m
  path: ./infra/k8s/apps
  prune: true
  dependsOn:
    - name: infrastructure
  sourceRef:
    kind: GitRepository
    name: flux-system
```

### E8. Push and verify (internal only)

```bash
git add infra/k8s
git commit -m "Run nginx on k3s via Flux"
git push
kubectl -n homelab get pods,svc,ingress
kubectl -n homelab port-forward svc/nginx 8080:80
# in another terminal:
curl -I http://localhost:8080
```

> **Verify:** the nginx Pod is `Running`, and `curl` returns `HTTP/1.1 200 OK`.
> Nothing is public yet — that happens in Part F and the cutover.

---

## Part F — cloudflared (the tunnel) inside the cluster

**Why:** the tunnel connector becomes a Pod in the cluster instead of a systemd
service on the host.

There are two ways to wire it, and which one you use depends on whether the
cluster can reach every backend:

- **Option B (clean, shown here):** the connector sends all traffic to Traefik,
  which routes by hostname. This is the end state - a new service is just an
  Ingress. It requires every backend to be reachable through the cluster.
- **Option A (bridge, `hostNetwork`):** keep the current config pointing at
  `localhost` ports. Use this first while services like Nextcloud still run on
  the host.

The steps below are Option B. See **Part G - Migrating the live server** for
when to use Option A and how to switch.

### F1. Route a wildcard DNS record (one time, on the workstation)

```bash
cloudflared tunnel route dns nginxtest '*.otakeessen.com'
```

This makes every `*.otakeessen.com` hostname enter the tunnel. Keep the existing
`homelab.otakeessen.com` record; it still points at the same tunnel.

### F2. Create `infra/k8s/apps/cloudflared/configmap.yaml`

Replace `<TUNNEL-UUID>` with your tunnel's UUID (the file name in
`~/.cloudflared/`).

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: cloudflared-config
  namespace: homelab
data:
  config.yml: |
    tunnel: <TUNNEL-UUID>
    credentials-file: /etc/cloudflared/creds/credentials.json
    no-autoupdate: true
    ingress:
      - hostname: "*.otakeessen.com"
        service: http://traefik.traefik.svc.cluster.local:80
      - service: http_status:404
```

> This wildcard form assumes the cluster can reach every backend (Option B). If
> you are bridging with `hostNetwork` (Option A), use explicit rules pointing at
> `localhost` ports instead - see Part G.

### F3. Create `infra/k8s/apps/cloudflared/deployment.yaml`

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cloudflared
  namespace: homelab
spec:
  replicas: 2
  selector:
    matchLabels:
      app: cloudflared
  template:
    metadata:
      labels:
        app: cloudflared
    spec:
      containers:
        - name: cloudflared
          image: cloudflare/cloudflared:latest
          args:
            - tunnel
            - --no-autoupdate
            - --config
            - /etc/cloudflared/config.yml
            - run
          volumeMounts:
            - name: config
              mountPath: /etc/cloudflared
              readOnly: true
            - name: creds
              mountPath: /etc/cloudflared/creds
              readOnly: true
      volumes:
        - name: config
          configMap:
            name: cloudflared-config
        - name: creds
          secret:
            secretName: cloudflared-credentials
```

### F4. Create `infra/k8s/apps/cloudflared/kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - configmap.yaml
  - deployment.yaml
```

### F5. Create the credentials Secret (never committed)

The tunnel credential is a secret. It must exist in the cluster, but must **not**
go into Git. Create it once, out of band:

```bash
kubectl create namespace homelab   # harmless if it already exists
kubectl -n homelab create secret generic cloudflared-credentials \
  --from-file=credentials.json=$HOME/.cloudflared/<UUID>.json
```

### F6. Push and verify

```bash
git add infra/k8s
git commit -m "Run cloudflared on k3s via Flux"
git push
kubectl -n homelab get pods
kubectl -n homelab logs deploy/cloudflared --tail=50
```

> **Verify:** logs say `Registered tunnel connection` and the Pods are
> `Running`. The website is now reachable at `https://homelab.otakeessen.com`
> **while the old host tunnel is still running** — two connectors on one tunnel
> is allowed, so there is no downtime.

---

## Part G — Migrating the live server (cutover order)

`node-one` is already serving several hostnames through one tunnel. Map what is
live before changing anything:

| Public hostname | Goes to | Host port |
|-----------------|---------|-----------|
| `homelab.otakeessen.com` | nginx (Compose) | 80 |
| `cloud.otakeessen.com` | Nextcloud AIO | 11000 (loopback only) |
| `laya.otakeessen.com` | laya-api (Compose) | 8001 |
| (Forgejo, if exposed) | Forgejo | 3000 |

### Do these first (no downtime)

Do **not** stop the nginx container yet - the live tunnel still points at it.
Start with the parts that touch nothing:

1. **Part A** - build and publish the nginx image.
2. **Part B** - install k3s with Traefik disabled; it binds no host ports, so the
   running site is untouched.
3. **Part C** - `flux bootstrap`.
4. Write and commit the `infra/k8s/**` manifests (Parts D and E).

### The one disruptive moment: swapping the web server on port 80

Traefik becomes a `LoadBalancer`, so k3s binds it to host ports **80/443** -
which the current nginx container is using. The swap:

```bash
# 1. Traefik + nginx manifests are committed and Flux is ready to reconcile.
# 2. Free ports 80/443 by stopping the old stack.
cd ~/Source/homelab/infra/nginx && docker compose down
# 3. Let Flux install Traefik and start the nginx Pod.
flux reconcile kustomization infrastructure --with-source
flux reconcile kustomization apps --with-source
```

Expect a brief 502 window (seconds to a couple of minutes) until Traefik and the
nginx Pod are Ready. Then verify:

```bash
kubectl -n traefik get svc traefik        # external IP assigned by k3s
kubectl -n homelab get pods,ingress
curl -I http://192.168.2.233              # Traefik on the LAN
curl -I https://homelab.otakeessen.com    # Cloudflare (host tunnel still up)
```

The public site is now served by the **in-cluster** nginx, reached through the
existing **host** cloudflared (whose `localhost:80` now lands on Traefik).

### Local network access

Because Traefik is a `LoadBalancer`, it answers on `node-one`'s `80`/`443`, so
`http://192.168.2.233` already serves the site on the LAN. To use names, add a
local DNS record (Pi-hole: **Local DNS -> DNS Records**):

| Name | Address |
|------|---------|
| `homelab.otakeessen.com` | `192.168.2.233` |

Only the nginx hostname has an Ingress behind Traefik for now. Nextcloud and
laya keep using their own ports on the LAN (`http://192.168.2.233:11000`,
`:8001`) until they move into the cluster.

### Moving cloudflared into the cluster

The catch: an in-cluster connector reaches services over the cluster network,
where `localhost` is the **Pod**, not the host. Nextcloud listens on
`127.0.0.1:11000` (loopback), which no Pod can reach. Two options:

**Option A - bridge with `hostNetwork` (recommended for 2.1).** Give the
cloudflared Pod the host's network namespace so `localhost` is the node's again
and the current config keeps working. In the ConfigMap use the **explicit**
rules, not the wildcard:

```yaml
ingress:
  - hostname: homelab.otakeessen.com
    service: http://localhost:80          # -> Traefik -> nginx Ingress
  - hostname: cloud.otakeessen.com
    service: http://localhost:11000       # -> Nextcloud on the host
  - hostname: laya.otakeessen.com
    service: http://localhost:8001        # -> laya-api on the host
  - service: http_status:404
```

Add to the Deployment pod spec (Part F3):

```yaml
spec:
  template:
    spec:
      hostNetwork: true
      dnsPolicy: ClusterFirstWithHostNet
```

Deploy it, confirm `https://homelab.otakeessen.com` still works, then stop the
host service:

```bash
sudo systemctl disable --now cloudflared
```

**Option B - route everything through Traefik (the end state).** Point the
tunnel ingress at `http://traefik.traefik.svc.cluster.local:80` (the wildcard in
Part F2), add Ingresses for Nextcloud and laya, and reach them while they are
still on the host with a `Service` plus manual `Endpoints` to `192.168.2.233`.
This needs Nextcloud's `APACHE_IP_BINDING` changed from `127.0.0.1` to `0.0.0.0`
and the AIO container recreated, because a loopback listener is unreachable from
a Pod.

Use Option A now to get cloudflared into a Pod with no service changes, then
convert to Option B as each service is migrated into the cluster.

### Retire the old Compose stack

```bash
cd ~/Source/homelab
git rm infra/nginx/docker-compose.yml
git commit -m "Retire nginx Compose stack"
git push
docker rm -f nginx    # only after the cutover is confirmed
```

### Rollback

Both the host and in-cluster connectors point at the same tunnel and may run at
once, so you can always fall back:

```bash
sudo systemctl enable --now cloudflared     # old tunnel back
flux suspend kustomization apps             # stop Flux changing the apps
```

---

## Part H — Updating the site from now on

A normal content change now flows like this:

1. Edit Markdown in `docs/wiki/`, or edit `infra/nginx/html/`.
2. Run `make wiki` (for wiki changes) and commit/push.
3. The GitHub Action in Part A builds a new image and prints a new digest.
4. Paste the new digest into `infra/k8s/apps/nginx/deployment.yaml` and push.
5. Flux rolls out a new nginx Pod automatically (watch it with
   `flux get kustomizations -A` and `kubectl -n homelab get pods -w`).

> Later we can add Flux **image automation** so step 4 happens by itself. Until
> then, pinning the digest by hand keeps deploys deliberate and reproducible,
> exactly like the [[laya-api container deploy (pinned GHCR image)]] pattern.

---

## Troubleshooting

| Symptom | Likely cause and fix |
|---------|----------------------|
| `flux get kustomizations` shows `False` | Read the message: `flux logs --all-namespaces`. Usually a typo in a path or YAML. |
| nginx Pod `ImagePullBackOff` | The GHCR package is private. Make it public (Part A5) or add a pull secret. |
| `curl` from port-forward works but public URL gives 404 | The Host header is not reaching Traefik, or the Ingress host does not match. Check `kubectl -n homelab get ingress` and the hostname spelling. |
| Public URL gives 502 | cloudflared cannot reach Traefik. Check `kubectl -n homelab logs deploy/cloudflared` and that Traefik's Service is `traefik` in namespace `traefik` on port 80. |
| cloudflared Pod `CreateContainerConfigError` | The `cloudflared-credentials` Secret is missing. Re-run Part F5. |
| Changes in Git do nothing | Flux polls every 10 minutes. Force it: `flux reconcile kustomization apps --with-source`. |
| Old site still shown after an update | The image digest in the Deployment was not changed. Pin the new digest (Part H). |

## Why this prepares phase 3 (Talos + k8s)

Everything under `infra/k8s/infrastructure/` and `infra/k8s/apps/` is plain
Kubernetes + Kustomize + Helm — it does not care which distribution runs it.
When the Talos cluster arrives you will:

1. `flux bootstrap` against the new cluster with a new `--path`
   (for example `infra/k8s/clusters/talos`).
2. Reuse the same `infrastructure/` and `apps/` folders.

Only the cluster-level bits differ (storage, node addresses, seeding the
tunnel secret). Adding the next service — Nextcloud, Forgejo — is now just
another folder under `infra/k8s/apps/` with a Deployment, a Service, and an
Ingress.

## Go-live checklist

- [ ] Part A: image builds, digest noted, package public
- [ ] Part B: `kubectl get nodes` shows `Ready`
- [ ] Part C: `flux check` passes
- [ ] Part D: Traefik Pod running
- [ ] Part E: nginx Pod running, internal `curl` returns 200
- [ ] Part F: cloudflared logs `Registered tunnel connection`
- [ ] Part F: `https://homelab.otakeessen.com` works
- [ ] Part G: host `cloudflared` service disabled
- [ ] Part G: `infra/nginx/docker-compose.yml` removed
- [ ] Wiki updated: `make wiki` run and committed
