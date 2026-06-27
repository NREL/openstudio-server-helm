#!/bin/bash

set -euo pipefail

NAMESPACE="${NAMESPACE:-openstudio-server}"
RELEASE="${RELEASE:-openstudio-server}"
INTERVAL_SECONDS="${INTERVAL_SECONDS:-900}"
ONCE="${ONCE:-0}"
LOG_FILE="${LOG_FILE:-./health-remediation-${RELEASE}-$(date +%Y%m%d-%H%M%S).log}"
ESCALATION_EMAIL="${ESCALATION_EMAIL:-}"
MAX_REMEDIATIONS_PER_CYCLE="${MAX_REMEDIATIONS_PER_CYCLE:-5}"
STATE_DIR="${STATE_DIR:-./.health-remediation-state}"
MAX_UNCORDONS_PER_CYCLE="${MAX_UNCORDONS_PER_CYCLE:-2}"
SAFE_WORKER_MAX_REPLICAS="${SAFE_WORKER_MAX_REPLICAS:-200}"
SAFE_WORKER_CPU_TARGET="${SAFE_WORKER_CPU_TARGET:-50}"
SAFE_WORKER_SCALE_POLICY="${SAFE_WORKER_SCALE_POLICY:-25}"
SAFE_WORKER_SCALE_UP_WINDOW_SECONDS="${SAFE_WORKER_SCALE_UP_WINDOW_SECONDS:-180}"
SAFE_WORKER_SCALE_DOWN_WINDOW_SECONDS="${SAFE_WORKER_SCALE_DOWN_WINDOW_SECONDS:-600}"
SAFE_WORKER_MEMORY_REQUEST="${SAFE_WORKER_MEMORY_REQUEST:-1Gi}"
SAFE_WORKER_MEMORY_LIMIT="${SAFE_WORKER_MEMORY_LIMIT:-2Gi}"
SAFE_WORKER_TERMINATION_GRACE="${SAFE_WORKER_TERMINATION_GRACE:-180}"

mkdir -p "$(dirname "$LOG_FILE")" "$STATE_DIR"

log() {
  printf '%s %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" | tee -a "$LOG_FILE"
}

escalate() {
  local subject="$1"
  local body="$2"

  log "ESCALATE: $subject"
  {
    printf '\n--- ESCALATION ---\n'
    printf 'Subject: %s\n' "$subject"
    printf '%s\n' "$body"
    printf '--- END ESCALATION ---\n'
  } | tee -a "$LOG_FILE"

  if [[ -n "$ESCALATION_EMAIL" ]] && command -v mail >/dev/null 2>&1; then
    printf '%s\n' "$body" | mail -s "$subject" "$ESCALATION_EMAIL"
  fi
}

patch_rollout() {
  local kind="$1"
  local name="$2"
  local reason="$3"
  local timestamp
  timestamp="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"

  kubectl -n "$NAMESPACE" patch "$kind" "$name" --type merge -p "$(cat <<EOF
{"spec":{"template":{"metadata":{"annotations":{"health-remediation.openstudio.io/last-remediated-at":"$timestamp","health-remediation.openstudio.io/reason":"$reason"}}}}}
EOF
)" >>"$LOG_FILE" 2>&1
}

record_state() {
  local key="$1"
  local value="$2"
  printf '%s\n' "$value" >"$STATE_DIR/$key.state"
}

read_state() {
  local key="$1"
  if [[ -f "$STATE_DIR/$key.state" ]]; then
    cat "$STATE_DIR/$key.state"
  fi
}

check_cluster() {
  log "Checking cluster reachability"
  if ! kubectl get nodes >>"$LOG_FILE" 2>&1; then
    escalate \
      "Cluster unreachable" \
      "kubectl cannot reach the cluster. The loop did not attempt remediation because this is a control-plane or connectivity issue."
    return 1
  fi

  local not_ready
  not_ready="$(kubectl get nodes --no-headers | awk '$2 !~ /Ready/ {print $1" "$2}')"
  if [[ -n "$not_ready" ]]; then
    escalate \
      "Cluster nodes not ready" \
      "These nodes are not Ready:\n$not_ready\nManual investigation required."
    return 1
  fi
}

check_release_objects() {
  local deployments
  deployments="$(kubectl -n "$NAMESPACE" get deployment -l "release=$RELEASE" --no-headers -o custom-columns=NAME:.metadata.name 2>>"$LOG_FILE" || true)"
  if [[ -z "$deployments" ]]; then
    escalate \
      "No release deployments found" \
      "No deployments were found in namespace '$NAMESPACE' for release '$RELEASE'."
    return 1
  fi
}

remediate_pod() {
  local pod_name="$1"
  local app_name="$2"
  local status="$3"

  case "$status" in
    ImagePullBackOff|ErrImagePull|CreateContainerConfigError)
      escalate \
        "Image/config issue in $app_name" \
        "Pod $pod_name is in '$status'. Restarting will not fix an image tag, registry, or configuration problem reliably."
      return 1
      ;;
    Pending|Unknown|CrashLoopBackOff|Error|Init:* )
      ;;
    *)
      return 0
      ;;
  esac

  local state_key="${app_name//\//-}"
  local previous
  previous="$(read_state "$state_key" || true)"
  if [[ "${previous:-0}" -ge 1 ]]; then
    escalate \
      "Persistent unhealthy pod for $app_name" \
      "Pod $pod_name is still unhealthy after a prior remediation attempt. Please inspect '$NAMESPACE/$app_name'."
    return 1
  fi

  log "Patching deployment/$app_name to trigger a safe rollout"
  patch_rollout deployment "$app_name" "pod-$status"
  record_state "$state_key" 1
}

remediate_scheduling_disabled_nodes() {
  local uncordoned=0
  local nodes
  nodes="$(kubectl get nodes --no-headers | awk '$2 ~ /Ready,SchedulingDisabled/ {print $1}' || true)"
  [[ -z "$nodes" ]] && return 0

  while IFS= read -r node_name; do
    [[ -z "$node_name" ]] && continue
    if [[ "$uncordoned" -ge "$MAX_UNCORDONS_PER_CYCLE" ]]; then
      break
    fi
    log "Uncordoning node $node_name (Ready,SchedulingDisabled)"
    kubectl uncordon "$node_name" >>"$LOG_FILE" 2>&1 || true
    uncordoned=$((uncordoned + 1))
  done <<<"$nodes"
}

remediate_worker_hpa_profile() {
  local hpa_name="worker-hpa"
  local max_replicas cpu_target
  max_replicas="$(kubectl -n "$NAMESPACE" get hpa "$hpa_name" -o jsonpath='{.spec.maxReplicas}' 2>>"$LOG_FILE" || true)"
  cpu_target="$(kubectl -n "$NAMESPACE" get hpa "$hpa_name" -o jsonpath='{.spec.metrics[0].resource.target.averageUtilization}' 2>>"$LOG_FILE" || true)"

  if [[ -z "$max_replicas" || -z "$cpu_target" ]]; then
    return 0
  fi

  if [[ "$max_replicas" -le "$SAFE_WORKER_MAX_REPLICAS" && "$cpu_target" -ge "$SAFE_WORKER_CPU_TARGET" ]]; then
    return 0
  fi

  log "Patching hpa/$hpa_name to safe scaling profile (max=$SAFE_WORKER_MAX_REPLICAS cpu=$SAFE_WORKER_CPU_TARGET)"
  kubectl -n "$NAMESPACE" patch hpa "$hpa_name" --type merge -p "$(cat <<EOF
{"spec":{"minReplicas":2,"maxReplicas":$SAFE_WORKER_MAX_REPLICAS,"metrics":[{"type":"Resource","resource":{"name":"cpu","target":{"type":"Utilization","averageUtilization":$SAFE_WORKER_CPU_TARGET}}}],"behavior":{"scaleUp":{"stabilizationWindowSeconds":$SAFE_WORKER_SCALE_UP_WINDOW_SECONDS,"policies":[{"type":"Pods","value":$SAFE_WORKER_SCALE_POLICY,"periodSeconds":60}]},"scaleDown":{"stabilizationWindowSeconds":$SAFE_WORKER_SCALE_DOWN_WINDOW_SECONDS,"policies":[{"type":"Pods","value":$SAFE_WORKER_SCALE_POLICY,"periodSeconds":60}]}}}}
EOF
)" >>"$LOG_FILE" 2>&1
}

remediate_worker_resources() {
  local mem_req mem_lim grace
  mem_req="$(kubectl -n "$NAMESPACE" get deployment worker -o jsonpath='{.spec.template.spec.containers[0].resources.requests.memory}' 2>>"$LOG_FILE" || true)"
  mem_lim="$(kubectl -n "$NAMESPACE" get deployment worker -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}' 2>>"$LOG_FILE" || true)"
  grace="$(kubectl -n "$NAMESPACE" get deployment worker -o jsonpath='{.spec.template.spec.terminationGracePeriodSeconds}' 2>>"$LOG_FILE" || true)"

  if [[ "$mem_req" == "$SAFE_WORKER_MEMORY_REQUEST" && "$mem_lim" == "$SAFE_WORKER_MEMORY_LIMIT" && "$grace" == "$SAFE_WORKER_TERMINATION_GRACE" ]]; then
    return 0
  fi

  log "Patching deployment/worker resources and termination grace (request=$SAFE_WORKER_MEMORY_REQUEST limit=$SAFE_WORKER_MEMORY_LIMIT grace=${SAFE_WORKER_TERMINATION_GRACE}s)"
  kubectl -n "$NAMESPACE" patch deployment worker --type json -p "$(cat <<EOF
[{"op":"replace","path":"/spec/template/spec/terminationGracePeriodSeconds","value":$SAFE_WORKER_TERMINATION_GRACE},{"op":"replace","path":"/spec/template/spec/containers/0/resources/requests/memory","value":"$SAFE_WORKER_MEMORY_REQUEST"},{"op":"replace","path":"/spec/template/spec/containers/0/resources/limits/memory","value":"$SAFE_WORKER_MEMORY_LIMIT"}]
EOF
)" >>"$LOG_FILE" 2>&1
}

check_pods() {
  local pod_lines unhealthy_count=0 remediation_count=0
  pod_lines="$(kubectl -n "$NAMESPACE" get pods -l "release=$RELEASE" --no-headers 2>>"$LOG_FILE" || true)"

  if [[ -z "$pod_lines" ]]; then
    escalate \
      "No pods found for release" \
      "No pods were returned for release '$RELEASE' in namespace '$NAMESPACE'."
    return 1
  fi

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local pod_name ready status restarts age app_name
    pod_name="$(awk '{print $1}' <<<"$line")"
    ready="$(awk '{print $2}' <<<"$line")"
    status="$(awk '{print $3}' <<<"$line")"
    restarts="$(awk '{print $4}' <<<"$line")"
    app_name="$(kubectl -n "$NAMESPACE" get pod "$pod_name" -o jsonpath='{.metadata.labels.app}' 2>>"$LOG_FILE" || true)"
    app_name="${app_name:-$pod_name}"

    if [[ "$ready" != "1/1" && "$status" != "Completed" ]] || [[ "$status" != "Running" && "$status" != "Completed" ]]; then
      unhealthy_count=$((unhealthy_count + 1))
      log "Unhealthy pod detected: $pod_name ready=$ready status=$status restarts=$restarts app=$app_name"
      if ! remediate_pod "$pod_name" "$app_name" "$status"; then
        return 1
      fi
      remediation_count=$((remediation_count + 1))
      if [[ "$remediation_count" -ge "$MAX_REMEDIATIONS_PER_CYCLE" ]]; then
        escalate \
          "Remediation cap reached" \
          "The loop hit the per-cycle remediation cap ($MAX_REMEDIATIONS_PER_CYCLE). Remaining issues require manual review."
        return 1
      fi
    fi
  done <<<"$pod_lines"

  if [[ "$unhealthy_count" -eq 0 ]]; then
    log "All release pods are healthy"
  fi
}

check_hpas() {
  local hpa_lines missing_hpas
  hpa_lines="$(kubectl -n "$NAMESPACE" get hpa --no-headers 2>>"$LOG_FILE" || true)"
  if [[ -z "$hpa_lines" ]]; then
    escalate \
      "No HPAs found" \
      "No HPA objects were found in namespace '$NAMESPACE'."
    return 1
  fi

  missing_hpas=""
  if ! grep -qE '^[[:space:]]*web[[:space:]]' <<<"$hpa_lines"; then
    missing_hpas="${missing_hpas} web"
  fi
  if ! grep -qE '^[[:space:]]*worker-hpa[[:space:]]' <<<"$hpa_lines"; then
    missing_hpas="${missing_hpas} worker-hpa"
  fi

  if [[ -n "$missing_hpas" ]]; then
    escalate \
      "Missing expected HPA objects" \
      "Expected HPA objects were not found:$missing_hpas"
    return 1
  fi

  log "HPA objects present"
}

cycle() {
  log "Starting health cycle for release=$RELEASE namespace=$NAMESPACE"
  check_cluster
  check_release_objects
  remediate_scheduling_disabled_nodes
  remediate_worker_hpa_profile
  remediate_worker_resources
  check_pods
  check_hpas
  log "Health cycle complete"
}

main() {
  log "Health-remediation loop starting"
  log "Prompt summary: check cluster and release every 15 minutes, prefer kubectl patch for safe rollouts, escalate by email when repair is unsafe."

  while true; do
    if ! cycle; then
      log "Cycle ended with escalation or failure"
    fi

    if [[ "$ONCE" == "1" ]]; then
      break
    fi

    log "Sleeping for ${INTERVAL_SECONDS}s"
    sleep "$INTERVAL_SECONDS"
  done
}

main "$@"
