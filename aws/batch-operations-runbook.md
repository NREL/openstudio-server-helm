# OpenStudio Server Batch Operations Runbook

This runbook captures lessons learned from high-scale completion runs and provides an operator checklist to finish remaining jobs quickly and safely.

## Primary Failure Modes Observed

1. Feeder starvation: worker fleet scaled faster than `simulations` queue refill.
2. Stale Redis analysis locks: `resque:analysis:*:queuing` blocked new queueing.
3. Infra auth drift: EBS CSI and cluster-autoscaler IRSA misconfiguration blocked scaling/mount workflows.
4. Web/admin saturation: `/admin` and `/resque` intermittently returned queue-full under load.
5. NFS mount coupling: pods scheduled onto incompatible nodes failed mount/init.
6. HPA drift: live HPA values diverged from intended scaling posture.
7. Failed-job schema variance: nested payload depth required recursive extraction for safe requeue.

## Preflight Gates (all must pass)

1. **Storage path healthy**
   - EBS CSI addon active
   - NFS provisioner pod ready
   - No sustained `FailedMount` events
2. **Queueing path healthy**
   - `web-background` replicas ready
   - `analyses` queue draining
   - No stale Redis locks
3. **Autoscaling healthy**
   - cluster-autoscaler running and credentialed
   - nodegroup max limits confirmed for target scale
4. **Web control plane healthy**
   - `/admin` returns 200
   - web pods have headroom (replicas + scheduling capacity)

## Runtime Sequence

1. Raise feeder throughput first (`web-background` replicas + `COUNT`).
2. Raise web control-plane floor during batch window.
3. Scale workers in controlled steps to target (2k -> 5k -> 10k -> 15k).
4. Keep `simulations` queue floor >= 10k where possible.
5. Requeue recoverable failed jobs in bounded batches when queue falls.

## Triggered Actions

### If `simulations` queue is near zero
1. Increase feeder throughput.
2. Check and clear stale lock keys.
3. Requeue recoverable failed jobs.

### If mounts fail or stale file handle appears
1. Restart NFS provisioner pod.
2. Verify mounts on web and feeder pods.
3. Keep NFS-dependent pods constrained to compatible node groups.

### If `/admin` or `/resque` returns queue-full
1. Increase web replicas/HPA floor.
2. Verify service endpoint spread across healthy web pods.
3. Use in-cluster fallback for admin actions (`kubectl port-forward svc/web 8080:80`).

## Failed Job Requeue Policy

1. Requeue only recoverable jobs into `simulations`/`analyses`.
2. Move unparsed/unrecoverable payloads to a quarantine list.
3. Avoid unbounded requeue floods; use batch sizes that keep queues primed without overload.

## Completion and Rollback

1. Completion criteria:
   - `simulations` queue at 0
   - running jobs near 0
   - `analyses` queue at 0
2. Roll back batch posture:
   - lower worker HPA floor and max
   - restore web and feeder baseline replicas
3. Capture post-run metrics:
   - total processed, failed, requeued, unrecoverable
   - peak worker/web/feeder scale and total runtime

## Hardening Follow-Ups

1. Add TTL/heartbeat cleanup for analysis lock keys.
2. Add alerts for queue starvation, stale lock age, mount failures, web 503 rate, and HPA drift.
3. Keep a versioned batch mode profile in Helm values for predictable fast-ramp operations.
