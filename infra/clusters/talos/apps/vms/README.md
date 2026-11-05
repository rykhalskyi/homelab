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

Masquerade networking (NAT) on the pod network; nothing is reachable inbound
unless you add a Service/port-forward. Console:

```bash
virtctl vnc omarchy -n vms
```

## Notes / risks

- Omarchy explicitly requires Secure Boot and TPM **off**; this manifest uses
  UEFI with `secureBoot: false` and no TPM device.
- **Hyprland needs GL.** This VM has no GPU passthrough, so expect software
  rendering (llvmpipe) and a sluggish VNC desktop. The installer is fine; a
  daily-driver desktop would want GPU passthrough or bare metal.
- **Talos caveat**: KubeVirt's `virt-launcher` userland is RHEL-based; upstream
  warns about very new host kernels. Kernel here is `6.18.57-talos`.
- `local-path` is RWO and node-local: no live migration; the VM is tied to
  `node-three`.
