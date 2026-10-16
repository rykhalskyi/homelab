---
tags: [navidrome, music, flac, subsonic, talos, kubernetes, flux, nfs, synology, nas, traefik, homelab-local, lan, ingress]
date: 2026-10-16
source_count: 0
---

# Navidrome on Talos (FLAC music server, LAN-only, read-only NAS library)

A **Navidrome** music server (Subsonic-API) on the `talos` cluster, serving the
FLAC library that already lives on the Synology NAS. The library is mounted
**read-only** over NFS; only Navidrome's own SQLite DB/cache is a cluster PVC.

It is served **LAN-only** at **`http://music.homelab.local`**. The host is under
`*.homelab.local`, which the Cloudflare tunnel never routes (it only forwards
`*.otakeessen.com`), so the app is unreachable from the internet.

> **Status:** manifests live on `infra/clusters/talos/apps/navidrome`, reconciled
> by Flux via the `apps` Kustomization. No new Secret is required. Reachable on
> the LAN only (was previously public at `music.otakeessen.com`).

## Working setup

| Piece | Value |
|-------|-------|
| Namespace | `navidrome` |
| Image | `navidrome/navidrome:0.64.2` (digest-pinned) |
| Container port | `4533` (`ND_PORT`) |
| Music mount | NFS `192.168.2.112:/volume1/media/Music` -> `/music` (**ro**) |
| Data mount | PVC `navidrome-data` (2Gi, `local-path`) -> `/data` |
| LAN host | `http://music.homelab.local` (Ingress -> Service `navidrome:80`) |
| Ingress VIP | `192.168.2.240` (Traefik's LoadBalancer IP, ARP-announced by Cilium L2) |

## Pieces

| File | Role |
|------|------|
| `infra/clusters/talos/apps/navidrome/namespace.yaml` | `Namespace: navidrome` (self-contained) |
| `infra/clusters/talos/apps/navidrome/pvc.yaml` | `navidrome-data` (2Gi, `local-path`) -> `/data` (SQLite + cache) |
| `infra/clusters/talos/apps/navidrome/deployment.yaml` | Navidrome (digest-pinned), NFS music volume (ro) + data PVC |
| `infra/clusters/talos/apps/navidrome/service.yaml` | `navidrome:80` -> `http` (4533) for Traefik |
| `infra/clusters/talos/apps/navidrome/ingress.yaml` | `music.homelab.local` -> service (LAN-only) |

Config is passed through `ND_*` environment variables:

- `ND_MUSICFOLDER=/music` — the read-only NAS library.
- `ND_DATAFOLDER=/data` — SQLite DB, cache, transcode cache (the PVC).
- `ND_SCANSCHEDULE=1h` — re-scan the NAS hourly (files are added out-of-band).
- `ND_LOGLEVEL=info`.

## Read-only NAS library

Navidrome never writes to the library, so the NFS export is mounted read-only
with an **inline pod volume** (the same Talos pattern as the Nextcloud
Deployment — no PV/PVC needed). Kubelet on whichever node runs the Pod performs
the mount and presents it at `/music`:

```yaml
volumes:
  - name: music
    nfs:
      server: 192.168.2.112
      path: /volume1/media/Music
      readOnly: true
```

> The export must be allowed for the cluster node IPs in the NAS NFS
> permissions (Synology: **Control Panel -> Shared Folder -> NFS Permissions**).
> Otherwise the Pod stays `ContainerCreating` with a mount error.

## Deploy

Merge to `main` and let Flux reconcile (or force it):

```bash
flux reconcile kustomization apps -n flux-system --with-source
kubectl --context talos -n navidrome get pods,pvc,ingress -w
```

## First run

Add a client hosts entry, then open `http://music.homelab.local`:

```
192.168.2.240 music.homelab.local
```

Create the **admin account** on the first-run screen (Navidrome asks for username
+ password the first time). Then create users / playlists as needed. The Subsonic
endpoint is the same host (`/rest/...`); point LAN clients such as Symfonium /
DSub / play:Sub at `http://music.homelab.local` (or the VIP directly).

## Verify

```bash
kubectl --context talos -n navidrome get pods,pvc,ingress
kubectl --context talos -n navidrome exec deploy/navidrome -- ls /music | head   # NAS visible
curl -s -H 'Host: music.homelab.local' http://192.168.2.240/ping                # pong
```

## Backups

There is **no backup** for this app, and none is needed for the library — the
FLAC files are authoritative on the NAS. `/data` holds only regenerable state
(SQLite DB with users, playlists and play counts). If playlists/play-counts
matter, add a restic CronJob to `s3://restic-backups/navidrome` following
[[File-volume backups on Talos (restic → MinIO) — plan]].

## Future / gotchas

- **Transcoding**: Navidrome transcodes off by default (it streams the original
  FLAC). If you enable transcoding, point it at a writable cache — `/data` (the
  PVC) is fine, but a large library can need more than 2Gi; bump the PVC.
- **Library scan size**: the first full scan of a large FLAC library takes a
  while and is CPU/IO heavy; `ND_SCANSCHEDULE=1h` keeps later scans incremental.
- **Image upgrades**: `navidrome/navidrome` is pinned by tag **and** digest —
  bump both together on upgrade.
- **LAN-only by design.** The host is `*.homelab.local`, so it is never exposed
  by the `*.otakeessen.com` tunnel. Remote listening needs the LAN (or a VPN).
  Navidrome still has its own login for untrusted LAN devices.
- **Node-independent VIP.** The ingress VIP `192.168.2.240` is a Cilium
  LoadBalancer IP ARP-announced by whichever node holds the lease, so it survives
  `node-two` going down like the other `*.homelab.local` services — see
  [[Cilium on Talos (Helm, kube-proxy-free)]].
- **NFS is read-only on purpose.** Do not mount the library read-write; keep the
  NAS as the single writer.
