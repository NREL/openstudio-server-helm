# OpenStudio Server Helm Chart Improvement Plan

## Purpose

Define a practical, implementation-ready plan to make this chart more resilient on Azimuth/OpenStack clusters, reduce failure modes during scaling, and increase the maximum **sustainably** scalable worker count.

This plan is based on current Kubernetes, Helm, KEDA, Calico, and OpenStack cloud-controller-manager guidance, plus observed behavior in this cluster.

---

## Success Criteria

1. Worker scaling no longer causes repeated `NodeNotReady`, `FailedCreatePodSandBox`, or secret-cache sync spikes.
2. `web`, `web-background`, `redis`, and `rserve` remain healthy during worker ramp events.
3. Helm upgrades stay in clean `deployed` state without drift/recovery operations.
4. Worker ceiling increases through repeatable, gate-controlled ramping (not one-off manual patching).
5. Chart defaults and validation prevent risky misconfiguration.

---

## Scope and Constraints

### In scope
- Helm chart templates, values structure, schema validation, operational scripts, docs/runbooks.
- Runtime controls accessible via `helm` and `kubectl`.

### Out of scope
- Cloud/provider internals not controllable from chart (`vs-api` platform behavior, node image builds, Calico install internals).

---

## Target Operating Model

1. **Service lane isolation**
   - Keep app-critical components (`web`, `web-background`, `redis`, `rserve`) isolated from worker churn.
   - Keep worker nodes dedicated for worker/prepull/worker-support workloads.

2. **Gate-driven scaling**
   - Scale worker ceilings only when health gates pass for a quiet window.
   - Stop at first sustained regression and auto-revert to last stable step.

3. **Safety-by-default chart behavior**
   - Conservative rollout/autoscaling defaults.
   - Strong schema validation and explicit feature flags for risky behaviors.

---

## Workstreams

## 1) Scheduling and Isolation Hardening

### Goals
- Prevent core services from being impacted by worker node churn.
- Avoid broad placement that amplifies failures.

### Changes
- Keep/verify:
  - `web` + `web-background`: required affinity to web node group.
  - `worker`: required affinity/nodeSelector to worker group.
  - `rserve`: worker lane.
  - `redis`: worker-preferred fallback (not strict pin if it creates availability risk).
- Add `topologySpreadConstraints` values/template wiring for worker Deployment:
  - default disabled, optional enable with `kubernetes.io/hostname`.

### Files
- `openstudio-server/templates/_scheduling.tpl`
- `openstudio-server/templates/web/web-deploy.yaml`
- `openstudio-server/templates/web-background/web-background-deploy.yaml`
- `openstudio-server/templates/worker/worker-deploy.yaml`
- `openstudio-server/templates/rserve/rserve-deploy.yaml`
- `openstudio-server/templates/redis/redis-deploy.yaml`
- `openstudio-server/values.yaml`
- `openstudio-server/values.registry-live.yaml`

### Acceptance criteria
- Core services stay Ready across worker ramp steps.
- Worker pods distribute without severe single-node concentration.

---

## 2) Autoscaling and Rollout Control

### Goals
- Reduce surge/churn-induced instability.
- Prefer smooth scaling over fast scaling.

### Changes
- Keep HPA/KEDA conservative behavior:
  - capped scale-up policies
  - stabilization windows
  - conservative scale-down
- Keep worker rolling update conservative (`maxSurge: 1`, `maxUnavailable: 0`) unless proven safe otherwise.
- Add clear values for stepwise ceiling control:
  - `worker_hpa.maxReplicas` as the authoritative cap
  - optional profile presets (`stable`, `ramp`, `burst`) documented.

### Files
- `openstudio-server/templates/worker/worker-hpa.yaml`
- `openstudio-server/templates/worker/worker-keda.yaml`
- `openstudio-server/templates/worker/worker-deploy.yaml`
- `openstudio-server/values.yaml`
- `openstudio-server/values.registry-live.yaml`

### Acceptance criteria
- No sustained growth in terminating/backoff worker pods after each step.
- Scale-up behavior remains predictable and reversible.

---

## 3) Pull Path and Startup Reliability

### Goals
- Minimize image and startup-path amplification during scale events.

### Changes
- Keep prepull scoped and controlled:
  - worker-only
  - one-shot warm mode
  - no extra warmed images by default
- Keep registry host patching scoped to worker nodes.
- Ensure pod-level `imagePullSecrets` and workload service account pull secrets are consistent.
- Keep digest/tag pinning and avoid mutable tags.

### Files
- `openstudio-server/templates/hooks/image-prepull-daemonset.yaml`
- `openstudio-server/templates/hooks/registry-hosts-patch-daemonset.yaml`
- `openstudio-server/templates/_scheduling.tpl`
- `openstudio-server/values.yaml`
- `openstudio-server/values.registry-live.yaml`

### Acceptance criteria
- No pull-storm behavior during worker ramp.
- No widespread `ImagePullBackOff` during normal step increases.

---

## 4) Health Gate Automation and Runbook Enforcement

### Goals
- Make safe scaling a repeatable operation, not operator memory.

### Changes
- Extend and standardize `scripts/openstudio-reliability` gates:
  - Node health (`Ready`, pressure states)
  - Pod regression states
  - event-pattern stop conditions
  - queue and divergence checks
- Add documented ramp procedure:
  - baseline → step +25/+50 → settle window → gate check → continue/rollback.

### Files
- `scripts/openstudio-reliability`
- `README.md`
- `openstack/TROUBLESHOOTING.md`

### Acceptance criteria
- Scale-up blocked automatically when hazard signals appear.
- Operator can run one deterministic command sequence for each ramp cycle.

---

## 5) Helm Chart Safety and Maintainability

### Goals
- Prevent silent config errors and upgrade surprises.

### Changes
- Add/expand `values.schema.json`:
  - autoscaling bounds
  - node selector/affinity structures
  - prepull and registry patch knobs
  - required/enum constraints
- Remove duplicate-key risk in profile files; enforce lint checks.
- Add upgrade notes and chart tests for key invariants.

### Files
- `openstudio-server/values.schema.json` (new or expanded)
- `openstudio-server/values.yaml`
- `openstudio-server/values.registry-live.yaml`
- `README.md`
- `openstack/README.md` (if needed for profile behavior)

### Acceptance criteria
- Mis-typed or unsafe values fail fast at template/lint time.
- Upgrades do not require release-secret surgery.

---

## Phased Delivery Plan

## Phase 0: Stabilization baseline (immediate)
- Freeze worker cap at last empirically stable ceiling.
- Confirm all core services Ready.
- Run reliability baseline snapshots.

## Phase 1: Chart safety and validation
- Implement schema validation.
- Normalize values/profile files (no duplicate keys).
- Document safe defaults and override semantics.

## Phase 2: Scaling controls + scheduling hardening
- Finalize HPA/KEDA behavior wiring.
- Add topology spread optional controls.
- Enforce node-lane isolation patterns.

## Phase 3: Operational gate automation
- Harden reliability script gates and ramp runbook.
- Add clear rollback path for each ramp step.

## Phase 4: Controlled ceiling discovery
- Stepwise ceiling probes with strict gates.
- Record stable ceiling and hazard threshold.
- Promote new ceiling into profile defaults only after repeated success.

---

## Risk Register

1. **Node/CNI bootstrap instability persists**
   - Mitigation: keep strict scale gates; stop widening on first sustained regression.

2. **Registry or secret-path latency spikes**
   - Mitigation: narrow prepull footprint, keep worker-only patch scope, enforce pull secret consistency.

3. **Helm drift from manual patches**
   - Mitigation: prefer values-driven changes; reduce direct live patching; use documented reconcile path.

4. **Service regressions during worker ramp**
   - Mitigation: hard lane separation and readiness gates for core services.

---

## Validation Matrix

Per ramp step, all must pass before next increase:

1. `web`, `web-background`, `redis`, `rserve` are Ready and stable.
2. Worker available replicas converge near desired without rising churn.
3. No sustained new spikes in:
   - `NodeNotReady`
   - `FailedCreatePodSandBox`
   - `failed to sync secret cache`
   - `ImagePullBackOff` / `ErrImagePull`
4. Helm release remains `deployed`.
5. Reliability gate script reports no blocker conditions.

If any fail: revert to last stable cap and hold.

---

## Recommended Immediate Next Actions

1. Add/expand `values.schema.json` and enforce in CI/lint.
2. Add worker topology spread controls (disabled-by-default, easy to enable).
3. Promote current reliability gate checks into a documented step-ramp command sequence.
4. Run next ceiling probe only after a sustained quiet window.

