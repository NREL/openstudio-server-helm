#!/usr/bin/env bash

set -euo pipefail

NAMESPACE="${NAMESPACE:-openstudio-server}"
LOOKBACK_HOURS="${LOOKBACK_HOURS:-6}"
STALL_MINUTES="${STALL_MINUTES:-10}"
MAX_ANALYSES="${MAX_ANALYSES:-25}"
ANALYSIS_ID="${ANALYSIS_ID:-}"
ONCE="${ONCE:-1}"
INTERVAL_SECONDS="${INTERVAL_SECONDS:-120}"
EXECUTE="${EXECUTE:-0}"
LOG_FILE="${LOG_FILE:-./stalled-analysis-remediation-${NAMESPACE}-$(date +%Y%m%d-%H%M%S).log}"

DB_LABEL_SELECTOR="${DB_LABEL_SELECTOR:-app=db}"
DB_CONTAINER_NAME="${DB_CONTAINER_NAME:-mongo-db}"
MONGO_URI="${MONGO_URI:-mongodb://openstudio:openstudio@localhost:27017/?authSource=admin}"
MONGO_DB_NAME="${MONGO_DB_NAME:-os_docker}"

REDIS_LABEL_SELECTOR="${REDIS_LABEL_SELECTOR:-app=redis}"
REDIS_CONTAINER_NAME="${REDIS_CONTAINER_NAME:-redis}"
REDIS_PASSWORD="${REDIS_PASSWORD:-openstudio}"

WEB_LABEL_SELECTOR="${WEB_LABEL_SELECTOR:-app=web}"
WEB_CONTAINER_NAME="${WEB_CONTAINER_NAME:-web}"
WEB_ACTION_URL_BASE="${WEB_ACTION_URL_BASE:-http://127.0.0.1}"

mkdir -p "$(dirname "$LOG_FILE")"

usage() {
  cat <<'USAGE'
Usage:
  remediate-stalled-analyses.sh [options]

Description:
  Detect analyses with only `data_points.status=na` and no queue progress,
  clear stale Redis analysis keys, and optionally re-trigger analysis start.

Default mode is dry-run (no writes). Use --execute to apply changes.

Options:
  -n, --namespace <name>         Kubernetes namespace (default: openstudio-server)
  --lookback-hours <hours>       Search recent analyses by datapoint creation window (default: 6)
  --stall-minutes <minutes>      Minimum inactivity age to treat as stalled (default: 10)
  --max-analyses <count>         Max stalled analyses to process per cycle (default: 25)
  --analysis-id <id>             Only process one analysis id
  --execute                      Apply changes (clear keys + POST action.json)
  --once                         Run one cycle and exit (default)
  --loop                         Run continuously
  --interval-seconds <seconds>   Sleep between cycles in loop mode (default: 120)
  --help                         Show this help text

Examples:
  # Safe preview
  ./scripts/remediate-stalled-analyses.sh --lookback-hours 12 --stall-minutes 15

  # Execute remediation for one known stuck analysis
  ./scripts/remediate-stalled-analyses.sh --analysis-id <analysis-id> --execute
USAGE
}

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

is_int() {
  [[ "${1:-}" =~ ^[0-9]+$ ]]
}

get_pod_name() {
  local selector="$1"
  kubectl -n "$NAMESPACE" get pods -l "$selector" -o jsonpath='{.items[0].metadata.name}' 2>>"$LOG_FILE" || true
}

find_stalled_analyses() {
  local db_pod="$1"
  local analysis_filter_js=""
  if [[ -n "$ANALYSIS_ID" ]]; then
    analysis_filter_js="if (analysisId !== '$ANALYSIS_ID') { continue; }"
  fi

  local js
  js="$(cat <<EOF
const dbName = "$MONGO_DB_NAME";
const lookbackHours = $LOOKBACK_HOURS;
const stallMinutes = $STALL_MINUTES;
const maxAnalyses = $MAX_ANALYSES;
const cutoff = new Date(Date.now() - (lookbackHours * 60 * 60 * 1000));
const mongoDb = db.getSiblingDB(dbName);

const grouped = mongoDb.data_points.aggregate([
  { \$match: { created_at: { \$gte: cutoff } } },
  { \$group: {
      _id: { analysis_id: "\$analysis_id", status: "\$status" },
      n: { \$sum: 1 },
      latest_dp_update: { \$max: "\$updated_at" }
    }
  },
  { \$group: {
      _id: "\$_id.analysis_id",
      status_pairs: { \$push: { k: "\$_id.status", v: "\$n" } },
      latest_dp_update: { \$max: "\$latest_dp_update" }
    }
  },
  { \$project: {
      _id: 1,
      counts: { \$arrayToObject: "\$status_pairs" },
      latest_dp_update: 1
    }
  },
  { \$sort: { latest_dp_update: -1 } },
  { \$limit: 5000 }
]).toArray();

let emitted = 0;
for (const row of grouped) {
  if (emitted >= maxAnalyses) { break; }
  const analysisId = row._id;
  $analysis_filter_js
  const counts = row.counts || {};
  const naCount = counts.na || 0;
  const queuedCount = counts.queued || 0;
  const startedCount = counts.started || 0;
  const completedCount = counts.completed || 0;
  if (!(naCount > 0 && queuedCount === 0 && startedCount === 0 && completedCount === 0)) {
    continue;
  }
  const analysis = mongoDb.analyses.findOne({ _id: analysisId }, { name: 1, updated_at: 1 });
  const latest = row.latest_dp_update || (analysis && analysis.updated_at);
  if (!latest) {
    continue;
  }
  const ageMinutes = Math.floor((Date.now() - new Date(latest).getTime()) / 60000);
  if (ageMinutes < stallMinutes) {
    continue;
  }
  const safeName = ((analysis && analysis.name) || "").replace(/[\\t\\n\\r]/g, " ");
  print([analysisId, safeName, naCount, new Date(latest).toISOString(), ageMinutes].join("\\t"));
  emitted += 1;
}
void 0;
EOF
)"

  kubectl -n "$NAMESPACE" exec "$db_pod" -c "$DB_CONTAINER_NAME" -- \
    mongosh --quiet "$MONGO_URI" --eval "$js" 2>>"$LOG_FILE" || true
}

clear_analysis_locks() {
  local redis_pod="$1"
  local analysis_id="$2"
  local queuing_key="resque:analysis:${analysis_id}:queuing"
  local completed_key="resque:analysis:${analysis_id}:completed"
  local removed
  removed="$(kubectl -n "$NAMESPACE" exec "$redis_pod" -c "$REDIS_CONTAINER_NAME" -- \
    redis-cli --no-auth-warning -a "$REDIS_PASSWORD" DEL "$queuing_key" "$completed_key" 2>>"$LOG_FILE" || true)"
  log "Cleared Redis keys for analysis=$analysis_id removed=${removed:-0} keys=[$queuing_key,$completed_key]"
}

trigger_analysis_start() {
  local web_pod="$1"
  local analysis_id="$2"
  local url="${WEB_ACTION_URL_BASE}/analyses/${analysis_id}/action.json"
  local payload='{"analysis_action":"start"}'
  local response http_code body

  response="$(kubectl -n "$NAMESPACE" exec "$web_pod" -c "$WEB_CONTAINER_NAME" -- sh -lc \
    "curl -sS -X POST '$url' -H 'Content-Type: application/json' --data '$payload' -w ' HTTP_STATUS:%{http_code}'" 2>>"$LOG_FILE" || true)"
  http_code="${response##*HTTP_STATUS:}"
  body="${response% HTTP_STATUS:*}"

  if [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
    log "Triggered action.json start for analysis=$analysis_id status=$http_code"
    return 0
  fi

  log "ERROR: action.json start failed for analysis=$analysis_id status=${http_code:-unknown} body=${body:-<empty>}"
  return 1
}

run_cycle() {
  local db_pod redis_pod web_pod
  db_pod="$(get_pod_name "$DB_LABEL_SELECTOR")"
  redis_pod="$(get_pod_name "$REDIS_LABEL_SELECTOR")"
  web_pod="$(get_pod_name "$WEB_LABEL_SELECTOR")"

  if [[ -z "$db_pod" || -z "$redis_pod" || -z "$web_pod" ]]; then
    log "ERROR: missing required pod(s): db=$db_pod redis=$redis_pod web=$web_pod"
    return 1
  fi

  local rows
  rows="$(find_stalled_analyses "$db_pod")"
  if [[ -z "$rows" ]]; then
    log "No stalled analyses found (lookback=${LOOKBACK_HOURS}h stall=${STALL_MINUTES}m)"
    return 0
  fi

  local count=0 started=0 failed=0
  while IFS=$'\t' read -r analysis_id analysis_name na_count latest_ts age_minutes; do
    [[ -z "${analysis_id:-}" ]] && continue
    [[ ! "${analysis_id}" =~ ^[0-9a-fA-F-]{36}$ ]] && continue
    count=$((count + 1))
    log "Candidate stalled analysis id=$analysis_id name=\"$analysis_name\" na=$na_count latest=$latest_ts ageMin=$age_minutes"
    if [[ "$EXECUTE" != "1" ]]; then
      continue
    fi

    clear_analysis_locks "$redis_pod" "$analysis_id"
    if trigger_analysis_start "$web_pod" "$analysis_id"; then
      started=$((started + 1))
    else
      failed=$((failed + 1))
    fi
  done <<<"$rows"

  if [[ "$EXECUTE" == "1" ]]; then
    log "Cycle summary execute=1 candidates=$count startTriggered=$started startFailed=$failed"
  else
    log "Cycle summary execute=0 candidates=$count"
  fi
}

main() {
  require_cmd kubectl

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--namespace)
        NAMESPACE="$2"
        shift 2
        ;;
      --lookback-hours)
        LOOKBACK_HOURS="$2"
        shift 2
        ;;
      --stall-minutes)
        STALL_MINUTES="$2"
        shift 2
        ;;
      --max-analyses)
        MAX_ANALYSES="$2"
        shift 2
        ;;
      --analysis-id)
        ANALYSIS_ID="$2"
        shift 2
        ;;
      --execute)
        EXECUTE=1
        shift
        ;;
      --once)
        ONCE=1
        shift
        ;;
      --loop)
        ONCE=0
        shift
        ;;
      --interval-seconds)
        INTERVAL_SECONDS="$2"
        shift 2
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        log "ERROR: unknown argument: $1"
        usage
        exit 1
        ;;
    esac
  done

  if ! is_int "$LOOKBACK_HOURS" || ! is_int "$STALL_MINUTES" || ! is_int "$MAX_ANALYSES" || ! is_int "$INTERVAL_SECONDS"; then
    log "ERROR: lookback-hours, stall-minutes, max-analyses, and interval-seconds must be integers"
    exit 1
  fi

  log "Stalled analysis remediation starting (namespace=$NAMESPACE execute=$EXECUTE once=$ONCE)"
  log "Config: lookbackHours=$LOOKBACK_HOURS stallMinutes=$STALL_MINUTES maxAnalyses=$MAX_ANALYSES analysisId=${ANALYSIS_ID:-<all>}"

  while true; do
    if ! run_cycle; then
      log "Cycle failed; no further action taken for this cycle"
    fi

    if [[ "$ONCE" == "1" ]]; then
      break
    fi
    sleep "$INTERVAL_SECONDS"
  done
}

main "$@"
