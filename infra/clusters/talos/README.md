# talos (placeholder)

Reserved for the Phase 3 Talos cluster. This name is temporary and will be
changed before `flux bootstrap` is run against it.

The `k8s` cluster (`../k8s/`) is the reference layout: a generated
`flux-system/` plus `apps.yaml`, `infrastructure.yaml`, and `kustomization.yaml`
pointing at this cluster's workloads. Each cluster is self-contained.
