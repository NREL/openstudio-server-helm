#!/usr/bin/env bash

set -euo pipefail

NAMESPACE="${NAMESPACE:-openstudio-server}"
INTERVAL_SECONDS="${INTERVAL_SECONDS:-30}"
ONCE="${ONCE:-0}"
LOG_FILE="${LOG_FILE:-./queue-autoscale-${NAMESPACE}-$(date +%Y%m%d-%H%M%S).log}"

REDIS_LABEL_SELECTOR="${REDIS_LABEL_SELECTOR:-app=redis}"
REDIS_CONTAINER_NAME="${REDIS_CONTAINER_NAME:-redis}"
REDIS_PASSWORD="${REDIS_PASSWORD:-openstudio}"
SIMULATIONS_QUEUE="${SIMULATIONS_QUEUE:-resque:queue:simulations}"
ANALYSES_QUEUE="${ANALYSES_QUEUE:-resque:queue:analyses}"
REQUEUED_QUEUE="${REQUEUED_QUEUE:-resque:queue:requeued}"

WEB_BACKGROUND_DEPLOYMENT="${WEB_BACKGROUND_DEPLOYMENT:-web-background}"
MANAGE_WEB_BACKGROUND="${MANAGE_WEB_BACKGROUND:-1}"
WEB_BACKGROUND_MIN_REPLICAS="${WEB_BACKGROUND_MIN_REPLICAS:-1}"
WEB_BACKGROUND_MAX_REPLICAS="${WEB_BACKGROUND_MAX_REPLICAS:-12}"
ANALYSES_PER_WEB_BACKGROUND="${ANALYSES_PER_WEB_BACKGROUND:-50}"
SIM_LOW_WATERMARK="${SIM_LOW_WATERMARK:-500}"
BOOST_WEB_BACKGROUND_WHEN_LOW_SIMS="${BOOST_WEB_BACKGROUND_WHEN_LOW_SIMS:-1}"
LOW_SIM_QUEUE_WEB_BACKGROUND_BOOST="${LOW_SIM_QUEUE_WEB_BACKGROUND_BOOST:-1}"

WORKER_HPA_NAME="${WORKER_HPA_NAME:-worker-hpa}"
WORKER_LABEL_SELECTOR="${WORKER_LABEL_SELECTOR:-app=worker}"
WORKER_MIN_REPLICAS_FLOOR="${WORKER_MIN_REPLICAS_FLOOR:-2}"
WORKER_MIN_REPLICAS_CEILING="${WORKER_MIN_REPLICAS_CEILING:-15000}"
WORKER_MIN_REPLICAS_MAX_STEP_UP="${WORKER_MIN_REPLICAS_MAX_STEP_UP:-200}"
WORKER_MIN_REPLICAS_MAX_STEP_DOWN="${WORKER_MIN_REPLICAS_MAX_STEP_DOWN:-50}"
SIMULATIONS_PER_WARM_WORKER="${SIMULATIONS_PER_WARM_WORKER:-50}"
ENFORCE_SIM_QUEUE_RATIO_FLOOR="${ENFORCE_SIM_QUEUE_RATIO_FLOOR:-1}"
SIMULATIONS_PER_RUNNING_WORKER_FLOOR="${SIMULATIONS_PER_RUNNING_WORKER_FLOOR:-30}"
MIN_SIMULATIONS_QUEUE_FLOOR="${MIN_SIMULATIONS_QUEUE_FLOOR:-800}"
MAX_SIMULATIONS_QUEUE_FLOOR="${MAX_SIMULATIONS_QUEUE_FLOOR:-150000}"

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

clamp() {
  local value="$1"
  local low="$2"
  local high="$3"
  if (( value < low )); then
    echo "$low"
  elif (( value > high )); then
    echo "$high"
  else
    echo "$value"
  fi
}

ceil_div() {
  local numerator="$1"
  local denominator="$2"
  if (( denominator <= 0 )); then
    echo 0
    return
  fi
  echo $(( (numerator + denominator - 1) / denominator ))
}

redis_queue_depth() {
  local pod_name="$1"
  local queue_name="$2"
  kubectl -n "$NAMESPACE" exec "$pod_name" -c "$REDIS_CONTAINER_NAME" -- \
    redis-cli --no-auth-warning -a "$REDIS_PASSWORD" LLEN "$queue_name" 2>>"$LOG_FILE"
}

get_redis_pod() {
  kubectl -n "$NAMESPACE" get pods -l "$REDIS_LABEL_SELECTOR" \
    -o jsonpath='{.items[0].metadata.name}' 2>>"$LOG_FILE" || true
}

get_deployment_replicas() {
  local deployment_name="$1"
  kubectl -n "$NAMESPACE" get deployment "$deployment_name" \
    -o jsonpath='{.spec.replicas}' 2>>"$LOG_FILE"
}

get_hpa_min_replicas() {
  local hpa_name="$1"
  kubectl -n "$NAMESPACE" get hpa "$hpa_name" \
    -o jsonpath='{.spec.minReplicas}' 2>>"$LOG_FILE"
}

get_running_worker_pods() {
  kubectl -n "$NAMESPACE" get pods -l "$WORKER_LABEL_SELECTOR" --field-selector=status.phase=Running \
    --no-headers 2>>"$LOG_FILE" | wc -l | tr -d ' '
}

safe_int() {
  local value="${1:-0}"
  if [[ "$value" =~ ^[0-9]+$ ]]; then
    echo "$value"
  else
    echo 0
  fi
}

scale_web_background() {
  local desired="$1"
  local current
  current="$(safe_int "$(get_deployment_replicas "$WEB_BACKGROUND_DEPLOYMENT")")"
  if (( current == desired )); then
    log "web-background replicas unchanged at $current"
    return
  fi

  log "Scaling deployment/$WEB_BACKGROUND_DEPLOYMENT from $current to $desired"
  kubectl -n "$NAMESPACE" scale deployment "$WEB_BACKGROUND_DEPLOYMENT" --replicas="$desired" >>"$LOG_FILE" 2>&1
}

web_background_managed_by_keda() {
  kubectl -n "$NAMESPACE" get scaledobject "$WEB_BACKGROUND_DEPLOYMENT" >/dev/null 2>>"$LOG_FILE"
}

web_background_managed_by_hpa() {
  kubectl -n "$NAMESPACE" get hpa "$WEB_BACKGROUND_DEPLOYMENT" >/dev/null 2>>"$LOG_FILE"
}

patch_worker_hpa_min() {
  local desired="$1"
  local current bounded_desired
  current="$(safe_int "$(get_hpa_min_replicas "$WORKER_HPA_NAME")")"

  bounded_desired="$desired"
  if (( desired > current )) && (( WORKER_MIN_REPLICAS_MAX_STEP_UP > 0 )); then
    local max_up_target=$(( current + WORKER_MIN_REPLICAS_MAX_STEP_UP ))
    if (( desired > max_up_target )); then
      bounded_desired="$max_up_target"
    fi
  elif (( desired < current )) && (( WORKER_MIN_REPLICAS_MAX_STEP_DOWN > 0 )); then
    local max_down_target=$(( current - WORKER_MIN_REPLICAS_MAX_STEP_DOWN ))
    if (( desired < max_down_target )); then
      bounded_desired="$max_down_target"
    fi
  fi

  if (( current == bounded_desired )); then
    log "worker-hpa minReplicas unchanged at $current"
    return
  fi

  if (( bounded_desired != desired )); then
    log "Bounding worker-hpa minReplicas change from requested=$desired to bounded=$bounded_desired (current=$current)"
  fi
  log "Patching hpa/$WORKER_HPA_NAME minReplicas from $current to $bounded_desired"
  kubectl -n "$NAMESPACE" patch hpa "$WORKER_HPA_NAME" --type merge \
    -p "{\"spec\":{\"minReplicas\":$bounded_desired}}" >>"$LOG_FILE" 2>&1
}

run_cycle() {
  local redis_pod raw_simulations raw_analyses raw_requeued simulations_depth analyses_depth requeued_depth
  redis_pod="$(get_redis_pod)"
  if [[ -z "$redis_pod" ]]; then
    log "ERROR: no redis pod found with label selector '$REDIS_LABEL_SELECTOR'"
    return 1
  fi

  raw_simulations="$(redis_queue_depth "$redis_pod" "$SIMULATIONS_QUEUE")"
  raw_analyses="$(redis_queue_depth "$redis_pod" "$ANALYSES_QUEUE")"
  raw_requeued="$(redis_queue_depth "$redis_pod" "$REQUEUED_QUEUE")"
  simulations_depth="$(safe_int "$raw_simulations")"
  analyses_depth="$(safe_int "$raw_analyses")"
  requeued_depth="$(safe_int "$raw_requeued")"

  # Effective simulation work = queued simulations + requeued simulations waiting to retry
  local effective_sim_depth=$(( simulations_depth + requeued_depth ))

  local desired_web_background desired_worker_min running_workers simulations_queue_floor low_simulations
  desired_web_background="$(ceil_div "$analyses_depth" "$ANALYSES_PER_WEB_BACKGROUND")"
  running_workers="$(safe_int "$(get_running_worker_pods)")"
  simulations_queue_floor="$SIM_LOW_WATERMARK"
  if (( ENFORCE_SIM_QUEUE_RATIO_FLOOR == 1 )); then
    simulations_queue_floor=$(( running_workers * SIMULATIONS_PER_RUNNING_WORKER_FLOOR ))
    simulations_queue_floor="$(clamp "$simulations_queue_floor" "$MIN_SIMULATIONS_QUEUE_FLOOR" "$MAX_SIMULATIONS_QUEUE_FLOOR")"
  fi

  low_simulations=0
  if (( simulations_depth < simulations_queue_floor )); then
    low_simulations=1
  fi

  if (( BOOST_WEB_BACKGROUND_WHEN_LOW_SIMS == 1 && low_simulations == 1 && analyses_depth > 0 )); then
    desired_web_background=$(( desired_web_background + LOW_SIM_QUEUE_WEB_BACKGROUND_BOOST ))
  fi
  desired_web_background="$(clamp "$desired_web_background" "$WEB_BACKGROUND_MIN_REPLICAS" "$WEB_BACKGROUND_MAX_REPLICAS")"

  desired_worker_min="$(ceil_div "$effective_sim_depth" "$SIMULATIONS_PER_WARM_WORKER")"
  desired_worker_min="$(clamp "$desired_worker_min" "$WORKER_MIN_REPLICAS_FLOOR" "$WORKER_MIN_REPLICAS_CEILING")"

  log "Queue depth: simulations=$simulations_depth requeued=$requeued_depth effectiveSim=$effective_sim_depth analyses=$analyses_depth runningWorkers=$running_workers requiredSimFloor=$simulations_queue_floor lowSimulations=$low_simulations"
  log "Target scale: web-background=$desired_web_background worker-hpa.minReplicas=$desired_worker_min"

  if web_background_managed_by_keda; then
    log "web-background KEDA ScaledObject detected; skipping direct replica management"
  elif web_background_managed_by_hpa; then
    log "web-background HPA detected; skipping direct replica management"
  elif (( MANAGE_WEB_BACKGROUND == 1 )); then
    scale_web_background "$desired_web_background"
  fi
  patch_worker_hpa_min "$desired_worker_min"
}

main() {
  require_cmd kubectl

  log "Queue autoscale loop starting (namespace=$NAMESPACE interval=${INTERVAL_SECONDS}s once=$ONCE)"
  while true; do
    if ! run_cycle; then
      log "Cycle failed; leaving current scaling unchanged"
    fi

    if [[ "$ONCE" == "1" ]]; then
      break
    fi

    sleep "$INTERVAL_SECONDS"
  done
}

main "$@"
