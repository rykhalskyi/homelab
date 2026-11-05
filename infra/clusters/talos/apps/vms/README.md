# Omarchy on KubeVirt (Talos cluster)

KubeVirt + CDI live in `infra/clusters/talos/infrastructure/`; the Omarchy VM
lives here. VMs are pinned to `node-three` (`kubernetes.io/hostname`), the only
node where VT-x, `/dev/kvm` and nested virt were validated.

## Capacity

`node-three` has 6 vCPU / 12 GiB and already runs `llamacpp`
(requests: 1 CPU / 4 GiB). The Omarchy VM requests 4 CPU / 6 GiB, so the two do
not fit together. Before starting Omarchy, free the node:

```bash
kubectl -n llamacpp scale deploy/llamacpp --replicas=0
```

Restore it after the VM is stopped (or move `llamacpp` to `node-two`, 20 GiB):

```bash
kubectl -n llamacpp scale deploy/llamacpp --replicas=1
```

## Install flow

1. Download the ISO to the workstation (6.1 GiB):

   <https://iso.omarchy.org/omarchy-4.5.0-x86.iso>

   Verify the published SHA-256/signature from <https://omarchy.org/>.

2. Upload it into `omarchy-iso` (never committed to Git):

   ```bash
   virtctl image-upload dv omarchy-iso -n vms --size=8Gi \
     --image-path=~/isos/omarchy-4.5.0-x86.iso \
     --no-create --insecure

   kubectl -n vms get dv omarchy-iso -w   # wait for Succeeded
   ```

3. Start the VM and open the console:

   ```bash
   virtctl start omarchy -n vms
   kubectl -n vms get vmi -w
   virtctl vnc omarchy -n vms
   ```

4. In the Omarchy installer:

   - Secure Boot and TPM are already off (UEFI with Secure Boot disabled, no
     vTPM), as Omarchy requires.
   - Select the 60 GiB `harddrive` for a full-disk install.
   - The installer defaults to full-disk encryption; set a passphrase.
   - Arch has virtio drivers in-kernel, so the disk is detected normally.

5. After installation, boot from the disk: set `bootOrder: 1` on `harddrive`
   and drop the ISO's boot order in `omarchy/vm.yaml` (commit and let Flux
   apply), or edit it in-cluster with `kubectl -n vms edit vm omarchy`.

## Access

The VM is fully isolated by `networkpolicy.yaml` (deny all ingress/egress);
the VNC console is the only channel:

```bash
virtctl vnc omarchy -n vms
```

A USB tablet (`devices.inputs`) is attached so the guest receives absolute
pointer coordinates; without it the default PS/2 mouse is relative and the VNC
cursor drifts/offsets from the guest pointer.

## Network isolation

`networkpolicy.yaml` selects the launcher pod (`kubevirt.io/domain: omarchy`)
and denies **all** ingress and egress. The guest cannot reach the LAN, other
pods/services, the Kubernetes API, or the internet. VNC still works because
`virtctl vnc` uses kubelet port-forward, not the pod network.

If the installer or updates need connectivity, temporarily lift it:

```bash
kubectl -n vms delete networkpolicy omarchy-isolated
# install / update
kubectl apply -k infra/clusters/talos/apps/vms
```

For "internet only" (block private ranges, allow public egress), replace the
deny-all policy with an egress allow-list using `ipBlock` and `except` for
`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `169.254.0.0/16` and
`100.64.0.0/10`. Keep DNS in mind: the guest uses cluster DNS, so either allow
that explicitly or point the guest at a public resolver.

## Notes / risks

- Omarchy explicitly requires Secure Boot and TPM **off**; this manifest uses
  UEFI with `secureBoot: false` and no TPM device.
- **Hyprland needs GL.** This VM has no GPU passthrough, so expect software
  rendering (llvmpipe) and a sluggish VNC desktop. The installer is fine; a
  daily-driver desktop would want GPU passthrough or bare metal.
- **Talos caveat**: KubeVirt's `virt-launcher` userland is RHEL-based; upstream
  warns about very new host kernels. Kernel here is `6.18.57-talos`.
- `local-path` is RWO and node-local: no live migration; the VM is pinned to
  `node-three`. Because of that, CDI's workload is pinned there too
  (`infrastructure/cdi/cdi-cr.yaml`) — otherwise an uploaded/imported volume can
  land on another node and the VM stays unschedulable.
