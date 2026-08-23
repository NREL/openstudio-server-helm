# Automated mitigation: stuck-node-remediation CronJob for aws-cni IP exhaustion

**Date:** 2026-08-20/21
**Related:** `docs/subnet-ip-exhaustion-network-request.md` (root cause + durable fix)

## Problem this automates away

During the worker-scale-up incident, individual worker pods repeatedly got
stuck forever in `Pending`/`ContainerCreating` with:

```
FailedCreatePodSandBox: ... plugin type="aws-cni" name="aws-cni" failed (add):
add cmd: failed to assign an IP address to container
```

This happens when a node's own slice of prefix-delegated subnet IPs is
exhausted, even though the node itself is perfectly healthy
(`Ready=True`, no taints, CPU/memory available) -- it's a per-pod
sandbox-creation failure, not a node-health condition.

**Why cluster-autoscaler doesn't fix this on its own:** CA's node-group
backoff/priority/expander logic only reacts to nodes that fail to *join* the
cluster. It has no mechanism to detect "node joined fine, but individual
pods scheduled onto it can never start." No CA flag change (including the
`--expander=least-waste` / `--balance-similar-node-groups=false` fix applied
earlier in this incident) touches this failure mode -- that fix only
influences *which node group* CA scales up, not what happens to pods that
land on an already-IP-exhausted node.

During the incident this had to be fixed manually, repeatedly:
1. Identify nodes with pods stuck on the specific IP-exhaustion error.
2. `kubectl cordon` those nodes (stop new pods landing there).
3. `kubectl delete pod` the stuck ones so their ReplicaSet reschedules them
   onto healthy capacity.
4. Let CA reclaim the cordoned node once it empties of any remaining,
   actually-Running pods.

## What was automated

`templates/worker/stuck-node-remediation-cronjob.yaml` (+
`stuck-node-remediation-rbac.yaml`) runs exactly this same four-step
sequence on a 5-minute schedule (`stuckNodeRemediation.schedule`), enabled
by default (`stuckNodeRemediation.enabled: true`).

Design notes:
- **Detection is a single `kubectl get events --field-selector=reason=
  FailedCreatePodSandBox` call**, filtered client-side for the
  `"failed to assign an IP address"` substring and joined in-memory against
  the current Pending worker pods -- not one `kubectl describe pod` per
  candidate pod. An early version of this script did per-pod `describe`
  calls and took several minutes against ~1000 Pending pods; the
  single-event-query version completes the same work in under 3 minutes
  end-to-end (identify + cordon + delete), even against ~1000 stuck pods.
- **Cluster-wide `FailedCreatePodSandBox` events can number in the tens of
  thousands** at 10k-replica scale (kubelet re-logs the failure roughly
  every 15-30s per stuck pod). Observed ~60MB / ~40k events during this
  incident -- the container's memory limit is set to 1Gi (with 512Mi
  request) to comfortably hold and `jq`-process that; an initial 256Mi
  limit OOMKilled the Job.
- **`stuckPodMinAgeMinutes` (default 8)** gates remediation on pod age, not
  just the presence of the error event, so a pod that's merely slow to
  schedule/pull an image for a few minutes is never touched -- only pods
  old enough that a transient issue would have self-resolved by now.
- **Only stuck (`Pending`) pods are deleted** -- any already-`Running` pods
  on the same cordoned node are left alone, so in-progress simulation work
  isn't disrupted. The node is reclaimed by cluster-autoscaler's normal
  scale-down once those Running pods finish naturally.
- **hostNetwork: true** on the Job pod itself, same reasoning as
  `templates/hooks/pre-delete-hook.yaml` -- a kubectl-only pod that skips
  CNI sandbox setup can't become a victim of the exact failure mode it's
  meant to remediate.
- **Image resolution reuses `containerdRegistryConfig.kubectlImage`** (the
  same ECR-hosted `bitnami/kubectl:latest` the prewarm DaemonSet's
  remove-taint container already uses) rather than routing through
  `imageWithRegistry`, since that helper only rewrites images when
  `localRegistry`/`global.images.*` rewriting is configured -- on AWS
  neither is, so a bare `bitnami/kubectl:latest` would otherwise pull
  straight from Docker Hub and can hit its pull-rate limit
  (`429 Too Many Requests`), which is exactly what happened on the first
  deploy attempt of this CronJob before the fix.

## Verification

Manually triggered via `kubectl create job --from=cronjob/...` against live
incident conditions (~1000+ Pending worker pods, ~23 affected nodes across
`worker-node-group-spot-2a`/`2d`): completed in ~2m39s, cordoned 23 nodes,
deleted 767 confirmed-stuck pods, left all co-located Running pods
untouched. Worker-ready count rose from 8,408 -> 9,617 within minutes of
the run completing.

## Relationship to the durable fix

This is a mitigation, not a fix. The actual root cause -- insufficient free
IPs in subnets for `us-west-2a`/`2b`/`2d` -- is addressed by the network
team request in `docs/subnet-ip-exhaustion-network-request.md` (new
subnets carved from the VPC's already-associated but unused `100.64.0.0/16`
CIDR). Once that lands, this CronJob should see zero remediation activity
in steady state, but is left enabled as a standing safety net for any
future recurrence of this specific failure mode in any AZ.
