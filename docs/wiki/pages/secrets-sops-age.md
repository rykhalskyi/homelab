---
tags: [sops, age, secrets, encryption, kubernetes, gitops, k8s, talos, operations]
date: 2026-10-08
source_count: 0
---

# Secrets with SOPS + age (local, out-of-band)

How secrets are handled in this homelab: they are **SOPS/age-encrypted, kept
local (never committed), and applied out of band**. This is the scheme for
**both** clusters — `k8s` (k3s) and `talos` — sharing one age key.

> Flux does **not** decrypt anything today. There is no `sops-age` Secret and no
> `spec.decryption` in either cluster. Encryption protects the *at-rest* copy on
> disk; you decrypt and `kubectl apply` yourself (or via `apply.sh`).

## Where things live

| Path | Tracked in git? | Purpose |
|------|-----------------|---------|
| `~/.config/sops/age/keys.txt` | no (local) | the age **private** key; the single source of decryption |
| `.sops.yaml` (repo root) | no (gitignored) | creation rule: which files, which age recipient |
| `infra/clusters/k8s/apps/secrets/` | no (gitignored) | k8s encrypted Secrets + `apply.sh` |
| `infra/clusters/talos/apps/secrets/` | no (gitignored) | talos encrypted Secrets + `apply.sh` |

```
infra/clusters/<cluster>/apps/secrets/
├── apply.sh                 # decrypt each *.sops.yaml and kubectl apply
├── kustomization.yaml       # reference list (not reconciled by Flux)
└── <name>.sops.yaml         # metadata in clear, data/stringData encrypted
```

`.gitignore` keeps all of this out of the repo:
```
*.sops.yaml
/infra/clusters/k8s/apps/secrets/
/infra/clusters/talos/apps/secrets/
```

The `.sops.yaml` rule encrypts only the payload, so `name`/`namespace`/key names
stay readable:
```yaml
creation_rules:
  - path_regex: infra/clusters/.*/apps/secrets/.*\.sops\.ya?ml$
    encrypted_regex: ^(data|stringData)$
    age: age1uppvtk2wv3vmphauazanpv8r2dmmsdd6ekz3vlpy0zjs9z9szf6q2yxg90
```

## Create / encrypt a secret

Write the plaintext manifest at the right path, then encrypt it **in place**.
SOPS finds `.sops.yaml` by walking up from the file, so run it inside the repo:

```bash
# 1. a normal Secret, but saved with the .sops.yaml suffix
cat > infra/clusters/talos/apps/secrets/myapp.sops.yaml <<'YAML'
apiVersion: v1
kind: Secret
metadata:
  name: myapp
  namespace: homelab
type: Opaque
stringData:
  API_KEY: change-me
YAML

# 2. encrypt in place (uses the .sops.yaml rule -> age recipient)
sops --encrypt --in-place infra/clusters/talos/apps/secrets/myapp.sops.yaml

# 3. confirm: metadata readable, values encrypted
head -20 infra/clusters/talos/apps/secrets/myapp.sops.yaml
```

Instead of step 1+2 you can create-and-edit interactively:
```bash
sops infra/clusters/talos/apps/secrets/myapp.sops.yaml   # opens $EDITOR, encrypts on save
```

## Edit / inspect

```bash
sops infra/clusters/talos/apps/secrets/myapp.sops.yaml    # edit (encrypts on save)
sops --decrypt infra/clusters/talos/apps/secrets/myapp.sops.yaml   # view plaintext
```

## Apply to a cluster

`apply.sh` decrypts every `*.sops.yaml` in its own directory and applies it.
It defaults to context `talos` / namespace `homelab`; override with `CTX`/`NS`:

```bash
# talos (default)
bash infra/clusters/talos/apps/secrets/apply.sh

# k8s
CTX=k8s bash infra/clusters/talos/apps/secrets/apply.sh
# or the k8s script
bash infra/clusters/k8s/apps/secrets/apply.sh
```

Manual equivalent:
```bash
sops --decrypt infra/clusters/talos/apps/secrets/myapp.sops.yaml \
  | kubectl --context talos -n homelab apply -f -
```

Because both clusters use the **same age key**, a `*.sops.yaml` file can be
copied between `k8s` and `talos` secret directories and applied to either.

## Rotate / manage the age key

```bash
# new key
age-keygen -o ~/.config/sops/age/keys.txt.new
# put its public key in .sops.yaml (age: <new-recipient>), then:
sops updatekeys infra/clusters/talos/apps/secrets/*.sops.yaml
sops updatekeys infra/clusters/k8s/apps/secrets/*.sops.yaml
mv ~/.config/sops/age/keys.txt.new ~/.config/sops/age/keys.txt
```

## Verify

```bash
# metadata visible, secrets not:
grep -E 'name:|namespace:|stringData:' infra/clusters/talos/apps/secrets/myapp.sops.yaml

# the secret exists in the cluster after apply:
kubectl --context talos -n homelab get secret myapp
```

## Gotchas

- **Never commit** the age key, `.sops.yaml`, or any `*.sops.yaml` — all are
  gitignored on purpose. Keep an offline copy of the key (see
  [[Backups: what to save and how to restore]]).
- Encryption **requires** the path to match a `.sops.yaml` creation rule,
  otherwise `sops -e` fails (or prompts for keys). If it complains, you are
  probably outside the `infra/clusters/<cluster>/apps/secrets/` pattern or
  running from the wrong directory.
- Only `data`/`stringData` are encrypted (`encrypted_regex`); don't put secrets
  anywhere else (e.g. labels, annotations, configmap values).
- Flux is **not** managing these — after `apply.sh`, a `kubectl` change to the
  Secret won't be reverted, and a lost local file can't be recovered from git.

## See also

- [[Talos CLI: common commands (dashboard, status, shutdown)]]
- [[kubectl contexts: switching between clusters]]
- [[Backups: what to save and how to restore]]
