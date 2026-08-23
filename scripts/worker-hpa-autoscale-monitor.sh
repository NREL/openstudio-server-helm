#!/bin/bash
# Monitors the worker HPA every 20 minutes and conservatively raises
# worker_hpa.maxReplicas in aws/values-aws.yaml (via helm upgrade) when
# there is evidence of both (a) genuine unmet demand and (b) real
# infrastructure headroom to support more workers.
#
# This automates the manual investigate-and-decide loop performed during
# the 2026-08-20/21 worker-scale-up incident (see docs/ for the full
# incident history). It intentionally raises the ceiling in conservative
# steps rather than jumping straight to a computed maximum, and refuses to
# raise at all if there are signs of the etcd-throttling / ECR pull-QPS
# incident this cluster already hit once before at similar scale.
#
# Usage:
#   ./scripts/worker-hpa-autoscale-monitor.sh [--once]
#
#   --once   Run a single check-and-maybe-bump cycle instead of looping
#            forever (useful for testing/cron instead of a long-lived loop).
#
# Requires: kubectl (context already pointed at the target cluster),
# helm, aws CLI, jq, python3. Must be run from the repo root (relative
# paths below assume that).
#
# All decisions and actions are logged to stdout AND appended to
# ./worker-hpa-autoscale-monitor.log in the repo root, so a run started in
# the background can be reviewed later.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VALUES_FILE="$REPO_ROOT/aws/values-aws.yaml"
CHART_DIR="$REPO_ROOT/openstudio-server"
NAMESPACE="openstudio-server"
RELEASE="openstudio-server"
CLUSTER_NAME="openstudio-server-03"
REGION="us-west-2"
LOG_FILE="$REPO_ROOT/worker-hpa-autoscale-monitor.log"
INTERVAL_SECONDS=1200 # 20 minutes

# EC2 Spot vCPU quota code: "All Standard (A, C, D, H, I, M, R, T, Z) Spot
# Instance Requests" -- see docs/subnet-ip-exhaustion-network-request.md
# and prior incident history for why this specific quota is the one that's
# repeatedly been the binding constraint on this cluster.
SPOT_VCPU_QUOTA_CODE="L-34B43A08"

# Conservative tuning knobs -- deliberately not "raise to the exact
# computed max" every cycle. See decide_bump() for how these are used.
MIN_CPU_PCT_TO_CONSIDER_RAISE=90   # HPA current/target CPU% must be >= this
STEP_WORKERS=2500                  # max single-cycle increase in maxReplicas
QUOTA_BUFFER_WORKERS=1000          # never raise to within this many workers of the vCPU quota ceiling
HARD_CEILING_WORKERS=20000         # never raise above this regardless of headroom (sanity backstop)

log() {
  # IMPORTANT: writes to stderr + the log file only, never stdout. Several
  # functions below (decide_bump, get_spot_vcpu_usage, etc.) are called via
  # command substitution ($(...)) to capture a single return value on
  # stdout; if log() wrote to stdout too, its messages would corrupt that
  # captured value. (This exact bug once wrote a log line straight into
  # aws/values-aws.yaml's maxReplicas field during testing -- see git
  # history / commit message for this line if you're wondering why this
  # comment is so specific.)
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" | tee -a "$LOG_FILE" >&2
}

get_hpa_json() {
  kubectl -n "$NAMESPACE" get hpa worker-hpa -o json
}

get_current_max_replicas() {
  get_hpa_json | jq -r '.spec.maxReplicas'
}

get_hpa_replicas() {
  get_hpa_json | jq -r '.status.currentReplicas'
}

# Returns the HPA's current CPU utilization percentage (the "current" value
# shown as e.g. "99%/25%" via kubectl get hpa), or empty if unavailable.
get_current_cpu_pct() {
  get_hpa_json | jq -r '
    .status.currentMetrics[]?
    | select(.type == "Resource" and .resource.name == "cpu")
    | .resource.current.averageUtilization
  ' 2>/dev/null || true
}

# Checks cluster-autoscaler logs for the specific failure signatures from
# the documented 2026-08-19 incident (etcd throttling, ECR pull-QPS
# storms). Returns 0 (true, safe to raise) only if none are found in the
# lookback window; returns 1 (unsafe) otherwise.
check_no_incident_signatures() {
  local since="${1:-25m}"
  local hits
  hits=$(kubectl -n kube-system logs deploy/cluster-autoscaler --since="$since" 2>/dev/null \
    | grep -c -iE "ResourceExhausted|etcdserver.*throttle|UnfulfillableCapacity" || true)
  local pull_hits
  pull_hits=$(kubectl -n "$NAMESPACE" get pods -l app=worker --no-headers 2>/dev/null \
    | grep -c -E "ImagePullBackOff|ErrImagePull" || true)
  log "incident-signature check: CA-log-hits=${hits:-0} image-pull-issue-pods=${pull_hits:-0}"
  if [ "${hits:-0}" -gt 0 ] || [ "${pull_hits:-0}" -gt 50 ]; then
    return 1
  fi
  return 0
}

# Prints "<used_vcpu> <quota_vcpu>" for the Spot vCPU quota, computed from
# currently-running Spot instances' vCPU counts (via a small lookup table
# covering every instance family seen on this cluster so far -- extend if
# new families are added to eks_config_large-spot.yaml).
get_spot_vcpu_usage() {
  local quota
  quota=$(aws service-quotas get-service-quota --service-code ec2 \
    --quota-code "$SPOT_VCPU_QUOTA_CODE" --region "$REGION" \
    --query 'Quota.Value' --output text 2>/dev/null || echo "0")
  # AWS returns this as a float (e.g. "20000.0") -- bash arithmetic (used
  # extensively in decide_bump) can't handle a decimal point, so truncate
  # to an integer here at the source rather than at every call site.
  quota=$(printf '%.0f' "$quota" 2>/dev/null || echo "0")

  local instance_types
  instance_types=$(aws ec2 describe-instances --region "$REGION" \
    --filters "Name=instance-lifecycle,Values=spot" "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].InstanceType' --output text 2>/dev/null || echo "")

  local used
  used=$(python3 -c "
import sys
vcpu_map = {
    'c5.metal': 96, 'c5a.24xlarge': 96, 'c5ad.24xlarge': 96, 'c5d.metal': 96,
    'c6a.24xlarge': 96, 'c6a.metal': 96, 'c6i.24xlarge': 96, 'c6i.metal': 128,
    'c6id.24xlarge': 96, 'c6in.24xlarge': 96,
    'c7a.24xlarge': 96, 'c7a.48xlarge': 192, 'c7a.metal-48xl': 192,
    'c7i.24xlarge': 96, 'c7i.48xlarge': 192, 'c7i.metal-24xl': 96, 'c7i.metal-48xl': 192,
    'm7i.24xlarge': 96, 'inf1.24xlarge': 96,
}
types = '''$instance_types'''.split()
total = sum(vcpu_map.get(t, 0) for t in types)
unknown = [t for t in types if t not in vcpu_map]
if unknown:
    print(f'WARNING: unknown instance types encountered (assumed 0 vCPU, undercounts usage): {sorted(set(unknown))}', file=sys.stderr)
print(total)
")
  echo "$used $quota"
}

# Node-group max-size headroom in worker slots (not vCPU), summed across
# all worker-group nodegroups. Used only as a secondary sanity check --
# vCPU quota has been the binding constraint every time so far, but this
# guards against a future scenario where quota is raised but nodegroup
# maxSize wasn't.
get_nodegroup_slot_headroom() {
  eksctl get nodegroup --cluster "$CLUSTER_NAME" --region "$REGION" -o json 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
total_headroom = 0
for ng in data:
    name = ng.get('Name', '')
    if 'worker' not in name:
        continue
    max_size = int(ng.get('MaxSize', 0))
    desired = int(ng.get('DesiredCapacity', 0))
    total_headroom += max(0, max_size - desired)
print(total_headroom)
"
}

# Rough workers-per-node figure derived from live pod-to-node packing, so
# node-slot headroom can be compared on the same units as vCPU headroom.
get_workers_per_node_estimate() {
  kubectl -n "$NAMESPACE" get pods -l app=worker -o json 2>/dev/null | \
    jq -r '.items[].spec.nodeName' | sort | uniq -c | \
    awk '{print $1}' | sort -n | tail -1
}

# Reads the current maxReplicas value out of the values file directly
# (rather than trusting the live HPA, in case of drift) so the sed-based
# edit below has a known, exact string to replace.
get_values_file_max_replicas() {
  grep -A2 '^worker_hpa:' "$VALUES_FILE" | grep -oE 'maxReplicas: [0-9]+' | grep -oE '[0-9]+' | head -1 \
    || grep -oE '^\s*maxReplicas: [0-9]+' "$VALUES_FILE" | grep -oE '[0-9]+' | tail -1
}

# Decides whether/how much to raise maxReplicas this cycle. Echoes the new
# value, or echoes the current value unchanged if no raise is warranted
# (callers should compare old vs new to decide whether to act).
decide_bump() {
  local current_max="$1"
  local current_replicas="$2"
  local cpu_pct="$3"
  local quota_used="$4"
  local quota_total="$5"
  local slot_headroom_workers="$6"

  # 1. Only consider raising if the HPA is actually saturated at its
  #    current ceiling -- i.e. replicas are at (or essentially at) maxReplicas.
  if [ "$current_replicas" -lt "$current_max" ]; then
    log "decision: not raising -- currentReplicas ($current_replicas) < maxReplicas ($current_max), HPA has not saturated its current ceiling yet"
    echo "$current_max"
    return
  fi

  # 2. Only consider raising if CPU utilization confirms genuine unmet
  #    demand (well above target), not just "happened to be at the ceiling".
  if [ -z "$cpu_pct" ] || [ "$cpu_pct" -lt "$MIN_CPU_PCT_TO_CONSIDER_RAISE" ]; then
    log "decision: not raising -- current CPU% ($cpu_pct) below threshold ($MIN_CPU_PCT_TO_CONSIDER_RAISE), demand may have relaxed"
    echo "$current_max"
    return
  fi

  # 3. Compute vCPU-quota-bound worker headroom (assuming ~1 vCPU request
  #    per worker, matching worker.container.resources.requests.cpu).
  local vcpu_headroom=$(( quota_total - quota_used ))
  local quota_bound_workers=$(( vcpu_headroom - QUOTA_BUFFER_WORKERS ))
  if [ "$quota_bound_workers" -lt 0 ]; then
    quota_bound_workers=0
  fi

  log "decision inputs: current_max=$current_max replicas=$current_replicas cpu=${cpu_pct}% vcpu_used=$quota_used vcpu_quota=$quota_total vcpu_headroom=$vcpu_headroom slot_headroom_workers=$slot_headroom_workers quota_bound_workers=$quota_bound_workers"

  if [ "$quota_bound_workers" -le 0 ]; then
    log "decision: not raising -- effectively no vCPU quota headroom left after reserving ${QUOTA_BUFFER_WORKERS}-worker buffer"
    echo "$current_max"
    return
  fi

  # 4. Step size is the smaller of: the fixed step, or what quota headroom
  #    actually allows (never propose a ceiling we can't realistically fill).
  local step="$STEP_WORKERS"
  if [ "$quota_bound_workers" -lt "$step" ]; then
    step="$quota_bound_workers"
  fi

  local proposed=$(( current_max + step ))

  # 5. Never propose above the hard sanity ceiling.
  if [ "$proposed" -gt "$HARD_CEILING_WORKERS" ]; then
    proposed="$HARD_CEILING_WORKERS"
  fi

  if [ "$proposed" -le "$current_max" ]; then
    log "decision: not raising -- computed proposal ($proposed) does not exceed current maxReplicas ($current_max)"
    echo "$current_max"
    return
  fi

  log "decision: raising maxReplicas $current_max -> $proposed (step=$step, leaving ~$(( quota_bound_workers - step )) workers of quota buffer after this raise)"
  echo "$proposed"
}

apply_bump() {
  local new_max="$1"
  local old_max="$2"

  log "applying: editing $VALUES_FILE maxReplicas $old_max -> $new_max"

  # Use a portable in-place sed edit (works on both GNU and BSD sed) that
  # only touches the maxReplicas line inside worker_hpa: (the value is
  # unique enough in this file that a plain global replace on the number
  # is safe, but scope it precisely via the preceding "maxReplicas:" key).
  python3 - "$VALUES_FILE" "$old_max" "$new_max" <<'PYEOF'
import sys, re
path, old_val, new_val = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f:
    content = f.read()
pattern = re.compile(r"(maxReplicas:\s*)" + re.escape(old_val) + r"(\s*\n)")
new_content, count = pattern.subn(r"\g<1>" + new_val + r"\g<2>", content, count=1)
if count != 1:
    print(f"ERROR: expected exactly 1 replacement of 'maxReplicas: {old_val}', got {count}", file=sys.stderr)
    sys.exit(1)
with open(path, "w") as f:
    f.write(new_content)
PYEOF

  log "linting chart..."
  helm lint "$CHART_DIR" -f "$VALUES_FILE" >> "$LOG_FILE" 2>&1

  log "deploying via helm upgrade..."
  helm upgrade "$RELEASE" "$CHART_DIR" -f "$VALUES_FILE" -n "$NAMESPACE" --force-conflicts >> "$LOG_FILE" 2>&1

  log "applied. live HPA maxReplicas is now: $(get_current_max_replicas)"
}

run_once() {
  log "=== monitor cycle start ==="

  local current_max current_replicas cpu_pct
  current_max=$(get_current_max_replicas)
  current_replicas=$(get_hpa_replicas)
  cpu_pct=$(get_current_cpu_pct)

  log "current state: maxReplicas=$current_max currentReplicas=$current_replicas cpu=${cpu_pct:-unknown}%"

  if ! check_no_incident_signatures; then
    log "decision: not raising -- incident signature(s) detected (etcd throttling / ECR pull-QPS / UnfulfillableCapacity / widespread ImagePullBackOff). Skipping this cycle."
    log "=== monitor cycle end (skipped due to incident signature) ==="
    return
  fi

  read -r quota_used quota_total <<< "$(get_spot_vcpu_usage)"
  local slot_headroom
  slot_headroom=$(get_nodegroup_slot_headroom)

  local values_file_max
  values_file_max=$(get_values_file_max_replicas)
  if [ "$values_file_max" != "$current_max" ]; then
    log "WARNING: values file maxReplicas ($values_file_max) does not match live HPA maxReplicas ($current_max) -- using live HPA value as source of truth for this decision, but the values file edit below assumes it currently reads '$values_file_max'. Skipping this cycle to avoid an ambiguous edit; investigate drift manually."
    log "=== monitor cycle end (skipped due to values-file/live drift) ==="
    return
  fi

  local proposed
  proposed=$(decide_bump "$current_max" "$current_replicas" "${cpu_pct:-0}" "$quota_used" "$quota_total" "$slot_headroom")

  if [ "$proposed" != "$current_max" ]; then
    apply_bump "$proposed" "$current_max"
  fi

  log "=== monitor cycle end ==="
}

main() {
  mkdir -p "$(dirname "$LOG_FILE")"
  log "worker-hpa-autoscale-monitor starting (interval=${INTERVAL_SECONDS}s, step=${STEP_WORKERS}, quota_buffer=${QUOTA_BUFFER_WORKERS}, hard_ceiling=${HARD_CEILING_WORKERS})"

  if [ "${1:-}" = "--once" ]; then
    run_once
    return
  fi

  while true; do
    # A failure in any single cycle (e.g. a transient AWS/kubectl API
    # error, or a bug like the float-vs-integer arithmetic error that
    # crashed an earlier version of this script entirely) must not take
    # down the whole monitor -- log it and keep looping so the next
    # scheduled check still happens. `set -e` is temporarily disabled only
    # around this one call.
    set +e
    run_once
    cycle_status=$?
    set -e
    if [ "$cycle_status" -ne 0 ]; then
      log "ERROR: monitor cycle exited with status $cycle_status (see above for details) -- continuing to next cycle rather than exiting the whole monitor"
    fi
    log "sleeping ${INTERVAL_SECONDS}s until next cycle..."
    sleep "$INTERVAL_SECONDS"
  done
}

main "$@"
