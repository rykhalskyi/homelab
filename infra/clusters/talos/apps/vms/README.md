# Windows 11 on KubeVirt (Talos cluster)

KubeVirt + CDI are installed from `infra/clusters/talos/infrastructure/` and the
VM lives here. VMs are pinned to `node-three` (`kubernetes.io/hostname`), the
only node where VT-x, `/dev/kvm` and nested virt were validated.

## Capacity

`node-three` has 6 vCPU / 12 GiB and already runs `llamacpp`
(requests: 1 CPU / 4 GiB). The Windows VM requests 4 CPU / 6 GiB, so the two do
not fit together. Before starting Windows, free the node:

```bash
kubectl -n llamacpp scale deploy/llamacpp --replicas=0
```

Restore it after the VM is stopped (or moved to `node-two`, which has 20 GiB):

```bash
kubectl -n llamacpp scale deploy/llamacpp --replicas=1
```

## Install flow

1. Upload the Windows ISO from the workstation (never committed to Git):

   ```bash
   virtctl image-upload dv win11-iso -n vms --size=10Gi \
     --image-path=/path/to/Win11.iso --no-create --insecure
   ```

   The virtio-win ISO imports automatically from the upstream URL.

   ```bash
   kubectl -n vms get dv
   # win11-iso and virtio-win-iso should reach Succeeded
   ```

2. Start the VM and open its console:

   ```bash
   virtctl start win11 -n vms
   kubectl -n vms get vmi -w          # wait for Running
   virtctl vnc win11 -n vms           # opens virt-viewer
   ```

3. In Windows Setup, the disk is invisible until the virtio driver is loaded:
   **Load driver** -> browse the virtio-win CD -> `viostor\w11\amd64` (or
   `vioscsi\w11\amd64`). The disk then appears and Setup can continue.

4. After first boot, run `virtio-win-guest-tools.exe` from the virtio-win CD to
   install the network, balloon and guest-agent drivers.

5. Make the disk boot first: set `bootOrder: 1` on `harddrive` in `vm.yaml`
   (and remove/stop using the ISO disk), then commit and let Flux reconcile, or
   edit the VM in-cluster for now.

## Access

The VM is on the pod network behind masquerade (NAT). Do not expose RDP
publicly. For ad-hoc access, port-forward the VMI:

```bash
kubectl -n vms port-forward vmi/win11 3389:3389
# then RDP to localhost:3389
```

## Notes / risks

- **Windows 11** needs UEFI + Secure Boot + vTPM; the manifest enables all
  three. TPM state is not persistent until the `VMPersistentState` feature gate
  and a `vmStateStorageClass` are enabled (needed for BitLocker).
- **Windows 10** is lighter: remove `devices.tpm`, replace the EFI bootloader
  with a BIOS one, and it will fit more comfortably in 6 GiB.
- **Talos caveat**: KubeVirt's `virt-launcher` userland is RHEL-based; upstream
  warns about very new host kernels. Kernel here is `6.18.57-talos`. If the VM
  misbehaves, this is the first suspect.
- `local-path` is RWO and node-local: no live migration, and the VM is tied to
  `node-three`.
- A Linux GUI VM can be added later with the same pattern (cloud image +
  `ubuntu-desktop`/`fedora-workstation` via cloud-init), but it shares the same
  RAM/CPU budget as Windows.
