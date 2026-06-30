#!/usr/bin/env bash

set -euo pipefail

NAMESPACE="${NAMESPACE:-openstudio-server}"
WORKER_HPA_NAME="${WORKER_HPA_NAME:-worker-hpa}"
WORKER_DEPLOYMENT="${WORKER_DEPLOYMENT:-worker}"
WORKER_LABEL_SELECTOR="${WORKER_LABEL_SELECTOR:-app=worker}"
STAGES="${STAGES:-2000,5000,10000,15000}"

MIN_READY_RATIO="${MIN_READY_RATIO:-0.95}"
HOLD_SECONDS="${HOLD_SECONDS:-180}"
CHECK_INTERVAL_SECONDS="${CHECK_INTERVAL_SECONDS:-15}"
STAGE_TIMEOUT_SECONDS="${STAGE_TIMEOUT_SECONDS:-1800}"

SANDBOX_FAIL_THRESHOLD_5M="${SANDBOX_FAIL_THRESHOLD_5M:-100}"
MAX_NON_RUNNING_ABS="${MAX_NON_RUNNING_ABS:-200}"
MAX_CREATE_CONTAINER_ERROR_ABS="${MAX_CREATE_CONTAINER_ERROR_ABS:-25}"
MAX_TERMINATING_ABS="${MAX_TERMINATING_ABS:-200}"

STAGE_SET_MIN_REPLICAS="${STAGE_SET_MIN_REPLICAS:-0}"
LOG_FILE="${LOG_FILE:-./worker-staged-ramp-${NAMESPACE}-$(date +%Y%m%d-%H%M%S).log}"

mkdir -p "$(dirname "$LOG_FILE")"

log() {
  printf '%s %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" | tee -a "$LOG_FILE"
}

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    log "ERROR: required command not found: $cmd"
    exit 1
  fi
}

safe_int() {
  local value="${1:-0}"
  if [[ "$value" =~ ^[0-9]+$ ]]; then
    echo "$value"
  else
    echo 0
  fi
}

get_hpa_min() {
  safe_int "$(kubectl -n "$NAMESPACE" get hpa "$WORKER_HPA_NAME" -o jsonpath='{.spec.minReplicas}' 2>>"$LOG_FILE" || true)"
}

set_hpa_stage_limit() {
  local stage="$1"
  local current_min desired_min
  current_min="$(get_hpa_min)"
  desired_min="$current_min"

  if (( STAGE_SET_MIN_REPLICAS == 1 || current_min > stage )); then
    desired_min="$stage"
  fi

  log "Patching hpa/$WORKER_HPA_NAME to stage target: maxReplicas=$stage minReplicas=$desired_min"
  kubectl -n "$NAMESPACE" patch hpa "$WORKER_HPA_NAME" --type merge \
    -p "{\"spec\":{\"maxReplicas\":$stage,\"minReplicas\":$desired_min}}" >>"$LOG_FILE" 2>&1
}

scale_worker_deployment() {
  local replicas="$1"
  log "Scaling deployment/$WORKER_DEPLOYMENT to replicas=$replicas"
  kubectl -n "$NAMESPACE" scale deployment "$WORKER_DEPLOYMENT" --replicas="$replicas" >>"$LOG_FILE" 2>&1 || true
}

failed_sandbox_events_5m() {
  local cutoff
  cutoff="$(($(date -u +%s) - 300))"
  kubectl -n "$NAMESPACE" get events --field-selector type=Warning -o json 2>>"$LOG_FILE" \
    | jq -r --argjson cutoff "$cutoff" '
      [
        .items[]
        | select(.reason == "FailedCreatePodSandBox")
        | (.lastTimestamp // .eventTime // .metadata.creationTimestamp // "") as $ts
        | select($ts != "")
        | select((($ts | fromdateiso8601?) // 0) >= $cutoff)
      ] | length
    ' 2>>"$LOG_FILE"
}

worker_pod_metrics() {
  kubectl -n "$NAMESPACE" get pods -l "$WORKER_LABEL_SELECTOR" -o json 2>>"$LOG_FILE" \
    | jq -r '
      def waiting_reason($r):
        any((.status.containerStatuses // [])[]?; (.state.waiting.reason // "") == $r);
      .items as $items
      | {
          total: ($items | length),
          running: ($items | map(select(.status.phase == "Running")) | length),
          non_running: ($items | map(select(.status.phase != "Running")) | length),
          terminating: ($items | map(select(.metadata.deletionTimestamp != null)) | length),
          create_container_error: ($items | map(select(waiting_reason("CreateContainerError"))) | length)
        }
      | [.total, .running, .non_running, .terminating, .create_container_error]
      | @tsv
    ' 2>>"$LOG_FILE"
}

deployment_ready_replicas() {
  safe_int "$(kubectl -n "$NAMESPACE" get deploy "$WORKER_DEPLOYMENT" -o jsonpath='{.status.readyReplicas}' 2>>"$LOG_FILE" || true)"
}

rollback_to_stage() {
  local rollback_stage="$1"
  log "ROLLBACK: reverting worker scale limits to stage=$rollback_stage"
  set_hpa_stage_limit "$rollback_stage"
  scale_worker_deployment "$rollback_stage"
}

validate_stage() {
  local stage="$1"
  local rollback_stage="$2"
  local stage_start healthy_since

  stage_start="$(date -u +%s)"
  healthy_since=0

  while true; do
    local now elapsed healthy_elapsed sandbox_5m
    now="$(date -u +%s)"
    elapsed=$((now - stage_start))
    sandbox_5m="$(safe_int "$(failed_sandbox_events_5m)")"

    local metrics total running non_running terminating create_error ready min_ready
    metrics="$(worker_pod_metrics)"
    total="$(safe_int "$(awk '{print $1}' <<<"$metrics")")"
    running="$(safe_int "$(awk '{print $2}' <<<"$metrics")")"
    non_running="$(safe_int "$(awk '{print $3}' <<<"$metrics")")"
    terminating="$(safe_int "$(awk '{print $4}' <<<"$metrics")")"
    create_error="$(safe_int "$(awk '{print $5}' <<<"$metrics")")"
    ready="$(deployment_ready_replicas)"
    min_ready="$(awk -v s="$stage" -v r="$MIN_READY_RATIO" 'BEGIN { printf("%d", s*r) }')"

    log "Stage=$stage elapsed=${elapsed}s ready=$ready running=$running total=$total nonRunning=$non_running terminating=$terminating createContainerError=$create_error failedCreatePodSandbox5m=$sandbox_5m"

    if (( sandbox_5m > SANDBOX_FAIL_THRESHOLD_5M )); then
      log "ERROR: failed sandbox events exceeded threshold ($sandbox_5m > $SANDBOX_FAIL_THRESHOLD_5M)"
      rollback_to_stage "$rollback_stage"
      return 1
    fi

    if (( elapsed > STAGE_TIMEOUT_SECONDS )); then
      log "ERROR: stage timeout exceeded for target=$stage (${elapsed}s > ${STAGE_TIMEOUT_SECONDS}s)"
      rollback_to_stage "$rollback_stage"
      return 1
    fi

    if (( ready >= min_ready )) \
      && (( non_running <= MAX_NON_RUNNING_ABS )) \
      && (( create_error <= MAX_CREATE_CONTAINER_ERROR_ABS )) \
      && (( terminating <= MAX_TERMINATING_ABS )); then
      if (( healthy_since == 0 )); then
        healthy_since="$now"
      fi
      healthy_elapsed=$((now - healthy_since))
      if (( healthy_elapsed >= HOLD_SECONDS )); then
        log "Stage target=$stage passed health hold (${healthy_elapsed}s >= ${HOLD_SECONDS}s)"
        return 0
      fi
    else
      healthy_since=0
    fi

    sleep "$CHECK_INTERVAL_SECONDS"
  done
}

main() {
  require_cmd kubectl
  require_cmd jq

  IFS=',' read -r -a stage_list <<<"$STAGES"
  if (( ${#stage_list[@]} == 0 )); then
    log "ERROR: STAGES is empty"
    exit 1
  fi

  local previous_stage current_ready
  current_ready="$(deployment_ready_replicas)"
  previous_stage="$current_ready"

  log "Starting staged worker ramp for namespace=$NAMESPACE stages=$STAGES"
  log "Gate config: minReadyRatio=$MIN_READY_RATIO hold=${HOLD_SECONDS}s timeout=${STAGE_TIMEOUT_SECONDS}s sandboxFailThreshold5m=$SANDBOX_FAIL_THRESHOLD_5M"

  local stage
  for stage in "${stage_list[@]}"; do
    stage="$(safe_int "$stage")"
    if (( stage <= 0 )); then
      log "ERROR: invalid stage value '$stage'"
      exit 1
    fi

    if (( stage < previous_stage )); then
      log "ERROR: stage values must be non-decreasing (stage=$stage previous=$previous_stage)"
      exit 1
    fi

    set_hpa_stage_limit "$stage"
    if ! validate_stage "$stage" "$previous_stage"; then
      exit 1
    fi
    previous_stage="$stage"
  done

  log "Completed staged worker ramp successfully. Final stage=$previous_stage"
}

main "$@"
