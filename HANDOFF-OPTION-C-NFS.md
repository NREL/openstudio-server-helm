# HANDOFF: Replace single-pod userspace NFS with a production-grade NFS server (OpenStack provider)

## Mission

Replace the chart's `nfs-server-provisioner` (single-pod **userspace Ganesha**) with a **kernel NFS server**
deployment that can sustain ~9,000 concurrent NFS client mounts plus heavy parallel simulation file I/O,
then restore the worker fleet to its intended 9,000 replicas and resume the interrupted benchmark run.

**This is OpenStack-provider specific work.** All new templates/values must be gated so that only
`provider.name == "openstack"` (i.e., clusters deployed with `openstack/values-openstack.yaml`) pick them up.
AWS/EKS (`aws/values-aws.yaml`) and bare defaults MUST keep working exactly as before — do not change their
behavior, image refs, or storage assumptions.

Everything below reflects the verified live state of cluster `openstudio-server-azimuth-openstack`
(kubeconfig context `openstudio-server-azimuth-openstack-admin@openstudio-server-azimuth-openstack`),
namespace `openstudio-server`, as of 2026-08-23 ~07:00 UTC.

---

## 1. Why (incident summary — do not re-litigate)

The current NFS stack is a vendored subchart (`openstudio-server/charts/nfs-server-provisioner`,
chart `nfs-server-provisioner-1.0.0`, image `quay.io/kubernetes_incubator/nfs-provisioner:v2.3.0`)
that runs **NFS-Ganesha 2.8.2 in userspace inside one pod**. Under this cluster's load it deadlocks repeatedly:

- 3 hard wedges on 2026-08-22/23 (~19:18, ~21:44, ~05:30–06:12 UTC), each requiring pod deletion + full client recycling
- Signature: `svc_ioq_flushv() writev failed (32)` spam in `/export/ganesha.log`; client mounts hang (`Stale file handle` or indefinite I/O hang) even though ganesha CPU is idle
- Degrades well before 9,000 clients: hangs observed at ~1,000 mounts; only reliably healthy ≤ ~250 mounts
- Silent blast radius: Resque children die/hang on NFS I/O *between* popping a job and writing datapoint status,
  so jobs vanish with **no Resque failure record** and datapoints freeze at `queued`. This very likely caused the
  original 73,829 "datapoint failure" results (only 671 ever completed normal) — i.e., prior "completed" data was
  garbage mostly because of this NFS fragility, not app bugs.

Conclusion: not fixable by tuning/restarts. Replace the server component.

## 2. Current architecture facts (verified live)

| Thing | Value |
|---|---|
| Namespace | `openstudio-server` |
| NFS server pod | `deploy/openstudio-server-nfs-server-provisioner` (subchart), 1 replica |
| Server image | `quay.io/kubernetes_incubator/nfs-provisioner:v2.3.0` (ganesha 2.8.2 in-process) |
| Backing store | Cinder RWO volume via claim **`nfs-pvc-data`** (~3.9 TiB, SC `ssd` = `cinder.csi.openstack.org`, WaitForFirstConsumer), mounted at `/export` in server pod |
| Export layout | `/export/pvc-<client-pv-uuid>/` per client PV; ganesha exports added dynamically over DBUS; `/export/vfs.conf` holds a placeholder `Export_Id = 0 -> /nonexistent` block (harmless CRIT noise at startup) |
| NFS Service | `openstudio-server-nfs-server-provisioner`, **ClusterIP 172.28.43.124**, ports TCP+UDP 111, 662, 875, 20048, 32803, 2049 |
| Client PV | `pvc-b7c98688-ef80-44fe-abcc-80456cb009fd`, `spec.nfs.server = 172.28.43.124` (the Service VIP), path `/export/pvc-b7c98688-ef80-44fe-abcc-80456cb009fd` |
| Client claim | **`nfs-pvc`** (3500Gi) mounted RWX at `/mnt/openstudio` by: `web`, `web-background`, every `worker` pod, `rserve` |
| Client mount options | kubelet mounts `-t nfs -o sync,vers=3` (comes from the provisioner-created PV) |
| App expectations | All components hard-code `/mnt/openstudio` (`os_server_project_path` in config.yml docker section). Workers read seed zips from and write results under this tree. `sim_root_path` resolves to `/mnt/openstudio/analysis_<uuid>` style dirs. |

### Workloads & scale (values: `openstack/values-openstack.yaml`)
- `worker.replicas: 9000` (deliberate; user-set). Each worker: request cpu 1 / mem 1Gi. Node group label: `capi.stackhpc.com/node-group=worker` (Azimuth autoscaler provisions nodes).
- **Live deviation:** workers were manually scaled to **200** during stabilization. The deployment spec still says 9000 — any `helm upgrade` restores 9000. Keep this in mind mid-migration.
- web ×1 (12cpu/60Gi), web-background ×1 (8cpu/32Gi, Resque queues `background,analyses,analysis_wrappers`), rserve ×1 (4cpu/8Gi, Rserve on 6311), db (mongo, own 192Gi PVC), redis (own 120Gi PVC) — all in same namespace; control-plane ×3 tainted; ~151 worker nodes + 2 web nodes.

### Interrupted benchmark state (to resume AFTER the fix)
- Gem repo: `~/179D/openstudio-bem-to-surrogate-gem`, project dir
  `outputs/run6_reruns_quickservicerestaurant_azimuth_v1`, submits via
  `bundle exec rake execute_sequential` against `http://localhost:61570/` (kubectl port-forward svc/web 61570:80).
- Mongo DB `os_docker` was wiped clean 2026-08-23 (backup: repo `tmp/cleanup-backup-20260823/*.jsonl`).
- Exactly ONE analysis exists: `batch6647_baseline_training_*` with 1,000 datapoints — **549 stuck `queued`**
  (their redis jobs vanished during the wedge) and need manual re-dispatch:
  ```bash
  # rails runner script in deploy/web-background: iterate DataPoint.where(status: :queued) { |dp| dp.submit_simulation }
  ```
- Manifest `osa_submit_manifest.jsonl` in the project dir was pruned to exactly ONE success record
  (`Batch6647_baseline_training`, single-line JSONL format — the parser reads line-by-line; keep records compact).
- Still owed: those 549 re-dispatches + resubmission of the other 77 batches (re-running rake will submit them;
  manifest intentionally lists only the live batch). Old manifests archived as `.bak-*` siblings.
- A monitor script exists at `/Users/achapin/tmp/opencode/osmon.sh` (checks rake process, dp statuses, rserve mount,
  FailedMount events, node readiness, non-running pods).

---

## 3. Design requirements for the replacement (OpenStack-specific)

### Chosen approach: kernel `nfsd` server Deployment fronting the SAME Cinder volume
Rationale: preserves the two-layer model (backing Cinder RWO volume + exported NFS PV) so **no data migration and
no client/PV changes** are needed, and kernel nfsd scales far beyond userspace ganesha.

1. **New template(s)** under `openstudio-server/templates/nfs/` (or replace the subchart usage behind a flag):
   - Deployment `openstudio-server-nfs-kernel` ×1 replica on a **web** node (affinity `capi.stackhpc.com/node-group=web`)
   - Image: a kernel-nfsd server image (e.g., `gists/nfs-server`, `erichough/nfs-server`, or a small custom
     Dockerfile adding `nfs-kernel-server` + `rpcbind` on Ubuntu 22.04 — prefer building/pinning our own in-repo
     for supply-chain safety; document the Dockerfile)
   - Mount claim **`nfs-pvc-data`** at `/export` (same backing volume ⇒ same data)
   - **securityContext: privileged: true** + volumeMount of hostPath `/proc/fs/nfsd` (kernel nfsd needs it) and
     `/lib/modules` (read-only, for the nfsd module) — verify these are required on the Azimuth Ubuntu 22.04 5.15 nodes
     and note that the namespace does NOT enforce restricted PSA (hostPID DaemonSets already run)
   - Startup: `rpcbind`, then `rpc.nfsd <THREADS>` with **THREADS ≥ 256** (kernel threads, the whole point vs ganesha),
     `exportfs -r`, exports defined via `/etc/exports` covering `/export *(rw,fsid=0?,insecure,no_subtree_check,no_root_squash)`
     — mirror whatever flags the current setup effectively provides (clients include kubelet mounting as root)
   - **Serve NFSv3 first** (identical port set: mountd 20048, statd 662, lockd 32803, rquotad 875, portmapper 111,
     nfsd 2049) so the EXISTING client PV (`vers=3`) keeps working untouched. Optionally enable v4.x too, but do NOT
     make clients change protocol in this pass.
   - Service: **reuse/replace with the same name `openstudio-server-nfs-server-provisioner`** OR a new Service —
     decision point below (see §5 Migration), because the client PV pins `spec.nfs.server = 172.28.43.124`.
     Safest: new Service named identically; if the old Service object must be deleted first, note that
     `helm upgrade` owns it (subchart) — plan the cutover as a single `helm upgrade`.
2. **Liveness/readiness probes MUST be `TCP 127.0.0.1:2049` (and an actual `showmount -e localhost` for readiness)**.
   Today's probe missed a fully dead NFS daemon (rpcbind alive, nfsd gone) — that failure mode caused hours of silent stall.
3. **Disable/retire the old subchart for openstack**: gate the vendored `charts/nfs-server-provisioner`
   rendering behind a value (e.g., `nfsServerProvisioner.enabled`, default true for backwards compat; set false in
   `openstack/values-openstack.yaml`). Do NOT delete the vendored subchart from the repo.
4. **Values plumbing** in `openstack/values-openstack.yaml`: new block e.g.
   ```yaml
   nfsKernelServer:
     enabled: true            # only rendered when provider.name == openstack AND this is true
     threads: 256             # rpc.nfsd thread count
     backingClaimName: nfs-pvc-data   # reuse existing 3.9TiB Cinder claim — DO NOT recreate it
     servicePortSet: [111, 662, 875, 20048, 32803, 2049]
   ```
   Guard templates with `{{- if and (eq .Values.provider.name "openstack") .Values.nfsKernelServer.enabled }}`.
5. **Do not touch** `db`, `redis`, their PVCs, the pulp/containerd mirror config, worker resource sizing, or
   anything AWS-specific. `nfs_pvc` (client claim) stays as-is.
6. Update `docs/` with a short ADR-style note: why ganesha was replaced, incident references, probe requirement,
   and the "recycle all NFS-client pods after any NFS restart" runbook rule.

### Known trap to design around
`DataPoint#submit_simulation` enqueues to Resque; jobs die SILENTLY (no failure record) when NFS hangs mid-child.
Any health verification must therefore be end-to-end (datapoints transition queued→started→completed), never just
"pod is Running".

---

## 4. Migration plan (execute in this order)

1. **Prep while old server still runs:** render + apply nothing yet; snapshot facts
   (`kubectl get pv pvc-b7c98688... -o yaml`, Service yaml, current dp counts).
2. **Scale workers to 0** (`kubectl scale deploy worker --replicas=0`) — they're idle anyway; avoids stale-mount cascade.
3. Stop the pipeline consumers: delete `web`, `web-background`, `rserve` pods (they hold the client mount).
4. Delete old server pod; **keep the `nfs-pvc-data` claim and all data**.
5. Apply the new kernel-server Deployment + Service (same Service name/ports; verify it gets a stable ClusterIP —
   if it differs from 172.28.43.124, patch `pv/pvc-b7c98688...` `.spec.nfs.server` to the new VIP BEFORE any client
   mounts; PV `.spec.nfs.server` is mutable via `kubectl patch pv ... --type merge`).
   Confirm from a throwaway pod: `mount -t nfs -o vers=3 <vip>:/export/pvc-b7c98688-ef80-44fe-abcc-80456cb009fd /mnt/t`
   and that prior data (`server/assets`, seed zips, analysis dirs) is visible.
6. Recreate `web`, `web-background`, `rserve` (delete pods; deployments recreate). Verify each can `ls /mnt/openstudio`.
7. **Staged worker ramp with mount-health gates** (sample 20 random pods per stage, require 100% healthy):
   500 → 1,000 → 3,000 → 9,000. Between stages, watch: ganesha-free kernel server load (`cat /proc/net/rpc/nfsd`
   th counters, pod CPU/mem), FailedMount events, dp throughput.
8. **End-to-end validation** (see §5).

## 5. Validation / acceptance criteria

- [ ] `status.json` via port-forward shows dps moving queued→started→completed at ≥ 20/s sustained with 9,000 workers
      (observed ceiling pre-fix: ~2/s briefly then stall)
- [ ] 60 consecutive minutes with ZERO new `FailedMount`/stale-handle events and dp `errored` count == 0
- [ ] Random sample (≥10) of completed dps have readable result files on NFS (`unzip -t` passes)
- [ ] Re-dispatch of the 549 queued dps completes; `batch6647_baseline_training` reaches completed
- [ ] `bundle exec rake execute_sequential` re-run submits the remaining 77 batches; console shows them progressing
      with real datapoint counts (not null-status zeros)
- [ ] Liveness probe demonstrably catches a killed nfsd (test: `kill` nfsd threads inside pod → pod restarts)
- [ ] `helm template` with `aws/values-aws.yaml` shows NO new resources (provider gating works)
- [ ] Chart version bumped; changes committed with message referencing this file

## 6. Operational rules going forward (put in docs/)

- After ANY NFS server pod restart: force-delete ALL `nfs-pvc` client pods (web, web-background, rserve, every worker)
  — stale handles otherwise linger silently for days (today's rserve/web-background lesson).
- Never trust "Running" alone: the only true NFS health signal is end-to-end dp status transitions + mount `ls` checks.
- Keep `osmon.sh`-style monitoring running during any large scale-up.

## 7. Environment access quick-reference

- kubeconfig context: `openstudio-server-azimuth-openstack-admin@openstudio-server-azimuth-openstack` (already default)
- Mongo creds: user `openstudio`, pass `ryLV0nsg^QG6kwJZ`, authDatabase `admin`, db `os_docker` (mongosh only; mongo shell binary absent)
- Redis: `redis://:<pass>@queue:6379`, pass in `openstack/values-openstack.yaml` (`redis_svc.url`)
- Port-forward for gem/console: `kubectl port-forward -n openstudio-server service/web 61570:80 --address 127.0.0.1`
- Helm release: `openstudio-server` rev 13, chart `./openstudio-server -f openstack/values-openstack.yaml`
- Repo state: branch `faster-scaleup`, MANY uncommitted changes — commit current state BEFORE starting migration edits
