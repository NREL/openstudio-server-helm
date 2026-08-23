# ADR + Runbook: kernel NFS server replaces userspace Ganesha provisioner (OpenStack)

Date: 2026-08-23
Scope: `openstack/values-openstack.yaml` installs only (provider-gated). AWS/EKS and bare-default installs are unchanged and keep the vendored subchart.

## Status

Accepted and deployed on cluster `openstudio-server-azimuth-openstack` (namespace `openstudio-server`).

## Context (incident summary)

The chart shipped a vendored `nfs-server-provisioner` subchart running **NFS-Ganesha 2.8.2 in userspace inside a single pod** (`quay.io/kubernetes_incubator/nfs-provisioner:v2.3.0`). Under this cluster's load it failed repeatedly and silently:

- Three hard wedges on 2026-08-22/23 (~19:18, ~21:44, ~05:30–06:12 UTC), each requiring pod deletion plus full client recycling.
- Signature: `svc_ioq_flushv() writev failed (32)` spam in `/export/ganesha.log`; client mounts hang with `Stale file handle` or indefinite I/O hang while ganesha CPU sits idle.
- Degrades well before target scale: hangs at ~1,000 mounts; only reliably healthy ≤ ~250 mounts. Target is 9,000 worker mounts.
- **Silent blast radius:** Resque children die/hang on NFS I/O *between* popping a job and writing datapoint status, so jobs vanish with no failure record and datapoints freeze at `queued`. This very likely produced most of the historical 73,829 "datapoint failure" results — prior "completed" data was garbage largely because of NFS fragility, not app bugs.

Conclusion: not fixable by tuning or restarts. Replace the server component.

## Decision

Replace Ganesha with a **kernel `nfsd` server Deployment fronting the same backing Cinder volume**, gated to OpenStack:

| Aspect | Choice |
|---|---|
| Templates | `templates/nfs/nfs-kernel-{backing-pvc,configmap,deploy,svc,static-pv}.yaml`, rendered iff `provider.name == "openstack"` **and** `nfsKernelServer.enabled` |
| Old subchart | Retired via dependency `condition: nfsServerProvisioner.enabled` (default `true`; `false` in openstack values). Vendored chart stays in repo. |
| Server image | `docker.io/gists/nfs-server@sha256:803f…` pinned by digest, run with a chart-owned `command:` override (see "gists image gotcha" below); self-hostable rebuild in `docker/nfs-kernel-server/` (Ubuntu 22.04 + nfs-kernel-server) for when a reachable private registry exists |
| Threads | `rpc.nfsd` with 256 kernel threads (`nfsKernelServer.threads`) |
| Protocol | NFSv3 only (`NFS_VERSION=3`). v4 behind a ClusterIP Service has stateful callback/lease semantics that break; identical reason the old StorageClass pinned `vers=3`. No client changes. |
| Backing store | Same claim `nfs-pvc-data` (Cinder RWO, ~3.9TiB) mounted at `/export` — Helm transfers ownership during one `helm upgrade` because name+spec match; no data movement |
| Service | Adopts the LEGACY Service identity (`<release>-nfs-server-provisioner`, ClusterIP `172.28.43.124`) via `nfsKernelServer.service.{name,clusterIP}` — see cutover log for why |
| Client PV cutover | None needed: the adopted legacy VIP keeps PV `pvc-b7c98688-…` valid unchanged (PV sources proved immutable, so the handoff's patch-the-PV plan was replaced by identity adoption) |
| Exports | One blanket line `/export *(rw,sync,insecure,no_subtree_check,no_root_squash)` — client PVs are subdirectories of that filesystem; mirrors what Ganesha provided per-directory |
| File locking | Kernel lockd (NLM) pinned to port 32803 via module params + sysctl in an initContainer, so v3 locking works through the Service exactly as Ganesha's userspace NLM did |
| Fresh installs | Static Retain PV (`<release>-nfs-kernel-static-share`, `storageClassName: nfs`, `/export/share`) binds `nfs-pvc` since dynamic provisioning died with the provisioner; binder matches class-name strings without needing the StorageClass object |

### The gists image gotcha (important)

The pinned `gists/nfs-server` 2.6.4 image is NOT erichough's original: its
`/bin/nfsd.sh` entrypoint is a hardcoded v4-only wrapper —

```sh
rpc.nfsd --no-udp -N 3 8      # v3 DISABLED, exactly 8 threads
rpc.mountd --no-udp -N 2 -N 3 -F
echo "$NFS_DIR $NFS_DOMAIN($NFS_OPTION)" > /etc/exports   # rewrites exports!
```

— which is precisely the failure mode this migration fixes (v4-only, 8
threads) and which also breaks on our read-only ConfigMap `/etc/exports`
mount. The Deployment therefore overrides `command` with the chart's own
supervisor (`start-nfsd.sh` in nfs-kernel-configmap.yaml):

- `rpc.nfsd -N 4 -N 4.1 -N 4.2 $THREADS` → v3-only, 256 threads
  (do NOT pass `-N 2`: this nfs-utils build doesn't compile NFSv2 and aborts
  with "Unsupported version")
- `rpc.mountd -F -p 20048`, `rpcbind`, `exportfs -r` on the mounted exports
- supervises rpc.mountd; exits if it dies so k8s restarts the pod
- tolerates images shipping `/var/lib/nfs/state` as a pre-existing FILE

Verified via `rpcinfo -p localhost` inside the pod after cutover:
`100003 v3 tcp 2049`, `100021 v1-v4 32803` (kernel NLM pinned by init
container), `100005 v1-v3 20048`.

## Cutover log (2026-08-23)

1. Snapshot PV/Service/PVC yaml to `tmp/migration-snapshot-20260823/`.
2. `kubectl scale deploy worker web web-background rserve --replicas=0`; drain verified.
3. Deleted legacy ganesha Deployment (backing claim untouched).
4. `helm upgrade … --set worker.replicas=0 --force-conflicts`
   (`--force-conflicts` needed: earlier manual `kubectl patch` owned
   `imagePullPolicy` on web/web-background).
5. Helm4 SSA pruned the subchart resources incl. legacy Service + StorageClass
   `nfs`. Kernel Deployment/Service up; Service recreated under legacy
   name+VIP on the following upgrade.
6. Throwaway privileged pod mount test `-o sync,vers=3,nolock` against
   `172.28.43.124:/export/pvc-b7c98688…`: prior data visible, read/write OK.
7. Recycled web/web-background/rserve per runbook rule #1.
8. Probe acceptance test: `rpc.nfsd 0` inside the pod → liveness failed →
   container auto-restarted <40s (the Ganesha blind spot is closed).
9. Staged ramp 500 → 1000 → 3000 → 9000 with 10–20-pod mount samples per
   stage: all OK. Only failure mode seen: single-shot `mount.nfs: Operation
   not permitted` FailedMount events on freshly-joined autoscaler nodes
   (statd not yet ready ~40s after node join); kubelet retry self-heals every
   time. At 9,000 replicas the node-group capacity ceiling left ~420 pods
   Unschedulable — an Azimuth quota/flavor matter, not NFS.

## Post-migration datapoint recovery notes

- Re-dispatch rule learned the hard way: do NOT bulk-resubmit queued
  datapoints until the worker fleet has fully converged. Jobs dispatched
  mid-ramp landed on workers whose nodes were still settling and died
  silently (the app's known pop→child gap), leaving status `queued` with no
  job in Redis.
- `status: started` is ambiguous: it mixes live simulations with wedge-era
  zombies. Liveness proxy: fresh mtimes under the dp's dir on NFS + a resque
  child ("Forked"/"Processing") on some worker pod. Sweep zombies only after
  the live wave drains.

### Probes (the lesson)

The 2026-08-23 outage lasted hours partly because the old probe checked "some process alive" while rpcbind lived and nfsd was dead. New probes:

- **Liveness = TCP :2049** — fails when nfsd stops accepting.
- **Readiness = exec `grep -q '^th [1-9]' /proc/net/rpc/nfsd`** — real kernel thread counter, not just a listening socket.
- Startup probe grants up to 5 minutes for first boot (module load, cold rpcbind).

### Deployment strategy

`strategy: Recreate` is mandatory: the backing claim is Cinder RWO, so RollingUpdate would deadlock two pods fighting over one volume attachment.

Privileged container + ro `/lib/modules` hostPath are required (image mounts the nfsd filesystem itself and modprobes against the host module tree); a `/proc/fs/nfsd` hostPath is deliberately NOT used. The namespace does not enforce restricted PSA (hostPID DaemonSets already run there).

## Consequences / operational rules (RUNBOOK)

1. **After ANY NFS server pod restart, force-delete ALL `nfs-pvc` client pods** (web, web-background, rserve, every worker):
   ```bash
   kubectl -n openstudio-server delete pod -l release=openstudio-server --force --grace-period=0 \
     # then let Deployments recreate; or targeted:
   kubectl -n openstudio-server delete pod -l app=web ...
   ```
   Stale handles otherwise linger silently for days (observed on rserve/web-background 2026-08-23).
2. **Never trust "Running" alone.** The only true NFS health signals are end-to-end datapoint transitions (queued→started→completed) and mount `ls` checks from inside pods. `DataPoint#submit_simulation` enqueues to Resque; jobs die SILENTLY if NFS hangs mid-child.
3. Keep an `osmon.sh`-style monitor running during any large scale-up.
4. Worker ramp after any NFS change must be staged with health gates (e.g. 500 → 1,000 → 3,000 → 9,000), sampling ~20 random pods per stage for mount health before proceeding.
5. To verify the server from a throwaway pod:
   ```bash
   kubectl -n openstudio-server run nfstest --rm -it --image=alpine:3.19 --restart=Never \
     -- sh -c 'apk add nfs-utils && mkdir -p /mnt/t && mount -t nfs -o vers=3,sync <svc>:/export/pvc-b7c98688-ef80-44fe-abcc-80456cb009fd /mnt/t && ls /mnt/t'
   ```

## References

- `HANDOFF-OPTION-C-NFS.md` (mission, verified live state, migration plan)
- Incident wedges: 2026-08-22/23 ganesha.log `svc_ioq_flushv()` signatures
- Chart values: `nfsServerProvisioner.enabled`, `nfsKernelServer.*`
