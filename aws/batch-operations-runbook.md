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
5. **Dependency readiness**
   - Redis latency and memory headroom acceptable
   - Mongo write/read latency stable under current feeder rate
   - NFS provisioner and mount checks healthy for web/background/rserve

## Runtime Sequence

1. Raise feeder throughput first (`web-background` HPA, KEDA ScaledObject, or replicas + `COUNT`).
2. Raise web control-plane floor during batch window.
3. Scale workers in controlled steps to target (2k -> 5k -> 10k -> 15k) with staged HPA max caps.
4. Keep `simulations` queue floor as a ratio of running workers (default 30 queued jobs/worker, bounded by absolute min/max).
5. Requeue recoverable failed jobs in bounded batches when queue falls.

## Operator Command Sequence (Reliability-First 15k Ramp)

1. Deploy reliability-first batch profile:
   - `helm upgrade --install openstudio-server ./openstudio-server --set provider.name=aws -f openstudio-server/values.yaml -f openstudio-server/values_batch_15k.yaml`
2. Start queue-aware floor control (leave feeder scaling to CPU HPA):
   - `NAMESPACE=openstudio-server WORKER_MIN_REPLICAS_CEILING=15000 WORKER_MIN_REPLICAS_MAX_STEP_UP=200 WORKER_MIN_REPLICAS_MAX_STEP_DOWN=50 ENFORCE_SIM_QUEUE_RATIO_FLOOR=1 SIMULATIONS_PER_RUNNING_WORKER_FLOOR=30 MIN_SIMULATIONS_QUEUE_FLOOR=800 MAX_SIMULATIONS_QUEUE_FLOOR=150000 ./scripts/queue-autoscale-loop.sh`
3. Start health remediation loop without forcing HPA max back to 15k:
   - `NAMESPACE=openstudio-server RELEASE=openstudio-server ENFORCE_WORKER_HPA_MAX_REPLICAS=0 ./scripts/health-remediation-loop.sh`
4. Run staged worker ramp with rollback guardrail:
   - `NAMESPACE=openstudio-server STAGES=2000,5000,10000,15000 SANDBOX_FAIL_THRESHOLD_5M=100 HOLD_SECONDS=180 MIN_READY_RATIO=0.95 ./scripts/worker-staged-ramp.sh`
5. If ramp guardrails trip, script auto-rolls back to the last stable stage; investigate runtime/network/node pressure before retry.

## Triggered Actions

### If `simulations` queue is near zero
1. Increase feeder throughput (`web-background` HPA floor or replicas).
2. Check and clear stale lock keys.
3. Requeue recoverable failed jobs.
4. Detect stalled analyses (`data_points=na`, no queue progress) and re-trigger start:
   - `./scripts/remediate-stalled-analyses.sh --lookback-hours 12 --stall-minutes 15`
   - `./scripts/remediate-stalled-analyses.sh --analysis-id <analysis-id> --execute`

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

## Staged Ramp Validation (Reliability-First)

Run each stage for a sustained window before advancing:

1. **2k stage**
   - `FailedCreatePodSandBox` stays at or below **100 per 5 minutes**
   - `FailedKillPod` rates low/stable
   - queue ratio floor maintained
2. **5k stage**
   - no sustained container runtime error spikes
   - node churn remains bounded
3. **10k stage**
   - feeder keeps simulations queue above ratio floor
   - web/admin plane remains responsive
4. **15k stage**
   - same gates as 10k plus steady-state completion throughput targets
   - if gates fail, roll back to last stable stage immediately

## Hardening Follow-Ups

1. Add TTL/heartbeat cleanup for analysis lock keys.
2. Add alerts for queue starvation, stale lock age, mount failures, web 503 rate, and HPA drift.
3. Keep a versioned batch mode profile in Helm values for predictable fast-ramp operations.

## Recommended Batch Profile + Queue Control

1. Deploy with `openstudio-server/values_batch_15k.yaml` layered over base values.
2. Run `scripts/queue-autoscale-loop.sh` with ratio-floor settings:
   - `ENFORCE_SIM_QUEUE_RATIO_FLOOR=1`
   - `SIMULATIONS_PER_RUNNING_WORKER_FLOOR=30`
   - `MIN_SIMULATIONS_QUEUE_FLOOR=800`
   - `MAX_SIMULATIONS_QUEUE_FLOOR=150000`
