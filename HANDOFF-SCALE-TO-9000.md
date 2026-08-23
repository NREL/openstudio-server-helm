# HANDOFF: Investigate & clear remaining roadblocks to 9,000 workers

Context: this follows HANDOFF-OPTION-C-NFS.md (kernel-NFS migration, same day).
The storage/dataplane work is DONE and verified. What remains is scaling the
worker fleet from ~600 to the 9,000 target and proving end-to-end throughput.
Everything below reflects verified live state of cluster
`openstudio-server-azimuth-openstack`, namespace `openstudio-server`,
as of 2026-08-23 ~19:30 UTC.

---

## 1. Mission

Take the fleet from current state to 9,000 healthy workers running real
simulations, with datapoint throughput >= 20/s sustained, and finish the
interrupted benchmark (batch6647 clean rerun + 77 remaining batches).
Investigate and clear every roadblock found on the way; document each with
evidence, not guesses.

## 2. Where things stand right now (verified)

### Dataplane (DONE -- do not re-litigate, see docs/nfs-kernel-server-migration.md)
- Kernel nfsd server pod `openstudio-server-nfs-kernel` runs **hostNetwork**,
  pinned to web node `openstudio-server-azimuth-openstack-web-4vqkj-5rx5z`
  (InternalIP **192.168.66.253**). Client PV `pvc-b7c98688-…` pins that IP.
  Zero NAT hops; verified 221MB/s fsync'd write from a worker-node pod.
- The chart auto-stops the node's own rpcbind/statd (they squat :111 and were
  the REAL blocker all along -- security groups were never involved).
- Readiness probe requires registered mountd (`rpcinfo` 100005) + nfsd threads.
- Legacy Service identity `<release>-nfs-server-provisioner` @ ClusterIP
  172.28.43.124 still exists for API compatibility but carries no dataplane.

### Fleet
- `deploy/worker`: spec 600 -> 568 ready and climbing when last checked.
  **The "540/600" gap you saw is benign fresh-node churn**: autoscaler adds a
  node, calico takes ~1 min to initialize (`FailedCreatePodSandBox …
  /var/lib/calico/nodename`), then kubelet pulls images, THEN pods go Ready.
  It resolves itself within minutes. Do not confuse it with a wedge.
- Worker requests: cpu 1 / mem 1Gi per pod.

### Benchmark state
- batch6647 rerun in flight: ~260 started / ~735 queued / 1 stale
  completed(failure). First wave started ~18:40 UTC; these are ComStock
  baseline models (`003_create_typical_building_from_model_comstock`) taking
  **1h+ of mostly-CPU time each**, so few completions before ~19:45 UTC is
  EXPECTED, not a stall. Liveness proxy for progress: `find <analysis dir>
  -type f -mmin -5 | wc -l` and non-D-state `openstudio run` processes.
- After drain: sweep stragglers (see §4.D), then `bundle exec rake
  execute_sequential` from `~/179D/openstudio-bem-to-surrogate-gem`
  re-submits the other 77 batches (manifest lists only batch6647 on purpose).

## 3. Known roadblocks between here and 9,000 (with evidence)

### R1. Hard node-group ceiling: 175 worker nodes (BLOCKER for 9,000)
Evidence: scheduler event `pod triggered scale-up:
[{MachineDeployment/az-aurora-179d/openstudio-server-azimuth-openstack-worker
9->10 (max: 175)}]`. The MachineDeployment CRD is not readable from the
cluster (Azimuth manages it out-of-band).
Math: worker nodes have **62 allocatable CPU / ~80Gi / 110 pods**; workers
request 1 CPU so density is ~58-60 pods/node => 175 nodes ~= 10,100 pods
max. 9,000 fits ONLY near-full ceiling. Earlier ramp stalled at 8,580 ready /
420 Unschedulable with 148 nodes.
INVESTIGATE/FIX:
  - Raise the Azimuth node group max size (Azimuth UI/API -- NOT in this
    cluster's API). Confirm project quotas first (next item).
  - Watch `TriggeredScaleUp` events + `kubectl get nodes -l
    capi.stackhpc.com/node-group=worker | grep -c Ready` during ramps.

### R2. OpenStack project quotas (UNVERIFIED -- audit first thing)
Quotas that bind before 175 nodes do: compute instances/vCPUs/RAM, volumes +
volume GB (~150 nodes x boot volume + existing 3.9TiB data volume), floating/
fixed network IPs (each node consumes subnet IPs; see
docs/subnet-ip-exhaustion-network-request.md for how IP exhaustion bit the
AWS side with per-pod sandbox failures).
Via app credentials (in ~/.zshrc): `source <(rg '^export OS_' ~/.zshrc)` then
`openstack quota show`; compare against current usage
(`openstack server list -f json | jq length` etc.).

### R3. Subnet IP space for node + pod network
Each new worker node consumes node IP + pod CIDR slice (calico). If the
portal-internal subnet is small, mass scale-up dies exactly like the AWS
subnet incident. Audit `openstack subnet list/show` free IPs BEFORE ramping
past current ~150 nodes.

### R4. NFS server headroom (single pod, single node -- measure, don't assume)
- 256 nfsd threads on one web node whose CPU sat at **2%** even while ~270
  sims wrote through it -- lots of headroom, BUT untested at 9,000-worker
  write bursts.
- Monitor during ramps: `grep "^th" /proc/net/rpc/nfsd` (deciles should stay
  mostly zero), established-conn count on the pod, client-side D-state scan
  (`ps -eo stat,args | grep energyplus | grep -v grep` looking for " D ").
- If threads saturate: raise `nfsKernelServer.threads` (values.yaml) --
  kernel threads are cheap.
- SPOF contract: server pinned to one node; if that node dies, follow the
  STORAGE CONTRACT comment in openstack/values-openstack.yaml (new node ->
  update values -> recreate PV -> recycle ALL clients).

### R5. Cinder volume performance ceiling (UNMEASURED at burst)
One shared ext4 volume serves ALL writes. Healthy at 424MB/s fsync'd solo,
but nobody has measured it under 1,000+ concurrent writers. Watch for: nfsd
io counters freezing, clients piling into killable-D rpc_wait, rising
`timeo` timeouts in dmesg-less world => use `nfsstat -rc` client-side or
simply dp throughput. If throttling appears, check the Cinder volume type/
QoS via openstack CLI (`openstack volume show <uuid of pvc-d7004bb2…>`,
`openstack volume qos list`) and consider a higher-performance type.

### R6. Pipeline singletons cap throughput (>= 20/s target)
Current idle-ish usage: web 16m/12cpu, web-background 20m/8cpu,
db 31m/8cpu, redis 6m/16cpu. The serial chain datapoint must traverse is
worker -> redis pop -> sim -> results POST to web -> mongo write.
At 300-900 workers everything loafs; the >= 20/s acceptance bar will be set
by whichever singleton saturates first during the FULL benchmark (78k dps).
Measure per-stage rates during the rake phase before blaming infra.

### R7. Resque silent job loss (process rule, not a bug to fix today)
Jobs die silently when children die mid-run (verified again today). Rules:
  - Dispatch/re-dispatch ONLY after the fleet has fully converged
    (readyReplicas == desired AND all mounts `ls` clean). Mid-ramp dispatch
    caused today's orphan wave.
  - After ANY mass recycle: re-dispatch `status: started` dps (their children
    died); `queued` jobs survive in redis and resume on their own.
  - End-of-run sweep: any dp not `completed` + `completed normal` gets one
    `submit_simulation` once the fleet is quiet. Beware mongoid cursor
    weirdness when updating while iterating (#each re-emits updated docs;
    harmless duplicates, app skips completed-normal).

### R8. stuck-node-remediation cronjob OOMKills at scale
Observed OOMKilled pods (16h ago), fine at low scale. At 9k workers its
`kubectl describe` loops get expensive. Bump
`stuckNodeRemediation` pod resources (values.yaml) BEFORE the big ramp, or
disable during ramps if it starts thrashing.

### R9. Fresh-node join storms (transients, self-healing -- budget time)
Every mass scale-up produces, per fresh node: calico init delay (~1 min),
image pulls (throttled by kubelet registryPullQPS=5; mitigated by the
containerdRegistryConfig prewarm DaemonSet for release images), occasional
one-shot `mount.nfs: Operation not permitted` (statd not up yet) that
kubelet retries successfully. Expect readyReplicas to lag replicas by
minutes-to-tens-of-minutes depending on how fast nodes materialize. Gate on
STABILITY, not on instantaneous readiness.

## 4. Execution plan (suggested order)

A. **Audit quotas + subnet IPs** (R2, R3) via openstack CLI. If compute/IP
   quota < what 175 nodes need, stop and file infra request first.
B. **Raise node-group max size** past 175 via Azimuth (R1).
C. **Let batch6647 drain** at 600; record sustained completions/s as the
   baseline throughput datapoint (R6 baseline). Sweep stragglers per R7.
D. **Rake phase**: `bundle exec rake execute_sequential` (port-forward
   svc/web 61570:80 already scripted in ~/.zshrc-era tooling; gem repo
   `~/179/openstudio-bem-to-surrogate-gem`, project
   outputs/run6_reruns_quickservicerestaurant_azimuth_v1). This submits the
   77 batches -- NOW there is enough work for a big fleet.
E. **Staged ramp with gates**: 1,000 -> 3,000 -> 6,000 -> 9,000. Per stage:
     - readyReplicas == desired (or explainably Pending-Unschedulable only)
     - 0 NEW FailedMount events over 10 min
     - sample 20 random pods: `ls /mnt/openstudio` OK, no D-state E+
     - dp throughput not DEGRADING vs previous stage
   Only advance when the previous stage holds for ~15 min.
F. **Throughput validation** at 9,000: >= 20 dps/s sustained, zero errored,
   60 min clean (acceptance criteria from HANDOFF-OPTION-C-NFS.md §5).

## 5. Environment quick-reference

- kubeconfig context: `openstudio-server-azimuth-openstack-admin@openstudio-server-azimuth-openstack` (default)
- OpenStack app credentials: exported in ~/.zshrc (`OS_*` vars);
  `rg '^export OS_' ~/.zshrc` + source them; token test: `openstack token issue`
- Live monitor script (dp counts + NFS health every 2 min):
  `/Users/achapin/tmp/opencode/nfsmon/monitor.sh` (pty session may be dead;
  just rerun it)
- Port-forward for gem/console: `kubectl -n openstudio-server port-forward service/web 61570:80 --address 127.0.0.1`
- Analysis ID for status.json: `53f05117-7c1f-434a-be2f-b666392e14b8`
- Mongo: exec into deploy/db, mongosh -u openstudio -p '<pass in openstack/values-openstack.yaml>' --authenticationDatabase admin os_docker; collection is `data_points`
- Helm release: `openstudio-server` rev ~22, chart `./openstudio-server -f openstack/values-openstack.yaml`
- Repo: branch `faster-scaleup`; latest commits 71fe628 (hostNetwork dataplane) etc.
- Snapshot of pre-migration objects: `tmp/migration-snapshot-20260823/`

## 6. Non-goals / guards

- Do NOT delete charts/nfs-server-provisioner or change AWS/default behavior.
- Do NOT touch db/redis/pulp/containerd config or worker resource sizing
  (mem 1Gi is measured-correct; cpu 1 is the density knob -- changing it
  changes R1 math).
- Do NOT bulk-dispatch datapoints mid-ramp (R7).
- Chart version was bumped to 0.8.0 for the NFS work; bump again for any new
  template changes and reference this file in commit messages.
