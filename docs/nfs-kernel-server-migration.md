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
| Server image | `docker.io/gists/nfs-server@sha256:803f…` pinned by digest; self-hostable rebuild in `docker/nfs-kernel-server/` (Ubuntu 22.04 + nfs-kernel-server) for when a reachable private registry exists |
| Threads | `rpc.nfsd` with 256 kernel threads (`nfsKernelServer.threads`) |
| Protocol | NFSv3 only (`NFS_VERSION=3`). v4 behind a ClusterIP Service has stateful callback/lease semantics that break; identical reason the old StorageClass pinned `vers=3`. No client changes. |
| Backing store | Same claim `nfs-pvc-data` (Cinder RWO, ~3.9TiB) mounted at `/export` — Helm transfers ownership during one `helm upgrade` because name+spec match; no data movement |
| Service | New Service `<release>-nfs-kernel`, same 6-port TCP+UDP contract (111, 662, 875, 20048, 32803, 2049) as the legacy one. Deliberately NOT reusing the legacy name: Helm does not delete resources dropped from a manifest on upgrade, so the old Service would collide. |
| Client PV cutover | Patch existing PV `pvc-b7c98688-…` `.spec.nfs.server` to the new Service DNS name (mutable field; DNS beats ClusterIP because it resolves at mount time and survives IP churn) |
| Exports | One blanket line `/export *(rw,sync,insecure,no_subtree_check,no_root_squash)` — client PVs are subdirectories of that filesystem; mirrors what Ganesha provided per-directory |
| File locking | Kernel lockd (NLM) pinned to port 32803 via module params + sysctl in an initContainer, so v3 locking works through the Service exactly as Ganesha's userspace NLM did |
| Fresh installs | Static Retain PV (`<release>-nfs-kernel-static-share`, `storageClassName: nfs`, `/export/share`) binds `nfs-pvc` since dynamic provisioning died with the provisioner; binder matches class-name strings without needing the StorageClass object |

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
