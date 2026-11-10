# Omarchy on KubeVirt (Talos cluster)

KubeVirt + CDI live in `infra/clusters/talos/infrastructure/`; the Omarchy VM
lives here. VMs are pinned to `node-three` (`kubernetes.io/hostname`), the only
node where VT-x, `/dev/kvm` and nested virt were validated.

## Capacity

`node-three` has 6 vCPU / ~24 GiB allocatable (~5950m CPU) and runs `llamacpp`
(requests: 1 CPU / 4 GiB) alongside the Omarchy VM. The VM has 4 vCPUs but
requests only 2 CPU / 6 GiB and sets a 4-CPU limit. The node's other workloads
request ~2.5 CPU, so total requests are ~5.5 of 5950m, leaving ~455m headroom.
CPU is shared when both are busy; the VM can use up to 4 CPU when llama.cpp is
idle.

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

The VNC console is the only inbound channel; the guest has public internet
access but cannot reach the LAN or the cluster:

```bash
virtctl vnc omarchy -n vms
```

A USB tablet (`devices.inputs`) is attached so the guest receives absolute
pointer coordinates; without it the default PS/2 mouse is relative and the VNC
cursor drifts/offsets from the guest pointer.

## Network policy (internet only)

`networkpolicy.yaml` selects the launcher pod (`kubevirt.io/domain: omarchy`)
and denies all ingress. Egress is limited to the public internet: `0.0.0.0/0`
minus `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `169.254.0.0/16` and
`100.64.0.0/10`, on TCP 80/443 and DNS. The guest cannot reach the LAN, other
pods/services, or the Kubernetes API. Cluster DNS (`kube-dns` at `10.96.0.10`)
is the one private exception, since the guest resolves through it. VNC still
works because `virtctl vnc` uses kubelet port-forward, not the pod network.

To restore full isolation, remove the `egress` rules from the policy (an empty
egress section denies everything). To allow LAN access temporarily, delete the
policy and re-apply it after:

```bash
kubectl -n vms delete networkpolicy omarchy-isolated
# install / update
kubectl apply -k infra/clusters/talos/apps/vms
```

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
