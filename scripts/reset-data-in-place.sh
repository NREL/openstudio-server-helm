#!/usr/bin/env bash
set -euo pipefail

# Destructive in-place data reset helper for OpenStudio Server.
# - Keeps the Helm release installed
# - Clears Redis keys
# - Drops all non-system Mongo databases
# - Removes shared analysis artifacts from /mnt/openstudio
#
# Defaults:
#   RELEASE_NAME=openstudio-server
#   NAMESPACE=openstudio-server
#
# Usage:
#   ./scripts/reset-data-in-place.sh --yes
#   ./scripts/reset-data-in-place.sh --yes --namespace openstudio-server --release openstudio-server

RELEASE_NAME="${RELEASE_NAME:-openstudio-server}"
NAMESPACE="${NAMESPACE:-openstudio-server}"
ASSUME_YES=false
CLEAR_REDIS=true
CLEAR_MONGO=true
CLEAR_SHARED_STORAGE=true
STOP_RUNNING_ANALYSES=true

usage() {
  cat <<'EOF'
Usage: reset-data-in-place.sh --yes [options]

Destructively clears OpenStudio app data WITHOUT uninstalling the Helm release.

What it clears by default:
  - Redis keys (FLUSHALL)
  - Mongo non-system databases (drops all except admin/config/local)
  - Shared analysis files on NFS (/mnt/openstudio/analysis_* and /mnt/openstudio/server/assets/analyses/*)
  - Stops active analyses before clearing

Options:
  --yes                     Required. Confirms destructive actions.
  --namespace <ns>          Kubernetes namespace (default: openstudio-server)
  --release <name>          Helm release name (default: openstudio-server)
  --no-clear-redis          Skip Redis FLUSHALL.
  --no-clear-mongo          Skip Mongo database drops.
  --no-clear-shared-storage Skip shared storage file deletion.
  --no-stop-running-analyses
                            Skip checking/stopping active analyses before clearing.
  -h, --help                Show this help text.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes)
      ASSUME_YES=true
      shift
      ;;
    --namespace)
      NAMESPACE="${2:-}"
      shift 2
      ;;
    --release)
      RELEASE_NAME="${2:-}"
      shift 2
      ;;
    --no-clear-redis)
      CLEAR_REDIS=false
      shift
      ;;
    --no-clear-mongo)
      CLEAR_MONGO=false
      shift
      ;;
    --no-clear-shared-storage)
      CLEAR_SHARED_STORAGE=false
      shift
      ;;
    --no-stop-running-analyses)
      STOP_RUNNING_ANALYSES=false
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ "${ASSUME_YES}" != "true" ]]; then
  echo "Refusing to run without --yes." >&2
  usage
  exit 1
fi

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl is required." >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required." >&2
  exit 1
fi

if ! kubectl -n "${NAMESPACE}" get deploy >/dev/null 2>&1; then
  echo "Namespace '${NAMESPACE}' is not reachable or does not exist." >&2
  exit 1
fi

get_single_running_pod_by_label() {
  local selector=$1
  local -a pods
  mapfile -t pods < <(
    kubectl -n "$NAMESPACE" get pods -l "$selector" -o json 2>/dev/null \
      | jq -r '.items[] | select(.status.phase == "Running") | .metadata.name' || true
  )
  if [[ ${#pods[@]} -eq 0 ]]; then
    echo "No running pods found for selector: $selector" >&2
    return 1
  fi
  if [[ ${#pods[@]} -gt 1 ]]; then
    echo "Warning: selector matched multiple running pods (${#pods[@]}): $selector; using ${pods[0]}" >&2
  fi
  echo "${pods[0]}"
}

active_analyses_summary() {
  local web_pod=$1
  kubectl -n "${NAMESPACE}" exec "${web_pod}" -- bash -lc "
    cd /opt/openstudio/server
    bundle exec rails runner '
      require %q(json)
      active_analyses = Analysis.where(:status.in => [%q(started), %q(queued)]).count
      active_jobs = Job.where(:status.in => [%q(started), %q(queued)]).count
      puts JSON.generate({active_analyses: active_analyses, active_jobs: active_jobs})
    '
  " | sed '/MONGODB | Unsupported client option/d'
}

request_stop_for_active_analyses() {
  local web_pod=$1
  kubectl -n "${NAMESPACE}" exec "${web_pod}" -- bash -lc "
    cd /opt/openstudio/server
    bundle exec rails runner '
      require %q(json)
      requested = 0
      failed = 0
      Analysis.where(:status.in => [%q(started), %q(queued)]).each do |analysis|
        begin
          analysis.run_flag = false if analysis.respond_to?(:run_flag)
          analysis.save! if analysis.changed?
          analysis.run_analysis(false, %q(stop), {})
          requested += 1
        rescue StandardError
          failed += 1
        end
      end
      puts JSON.generate({stop_requested: requested, stop_failed: failed})
    '
  " | sed '/MONGODB | Unsupported client option/d'
}

echo "Starting in-place data reset:"
echo "  release:              ${RELEASE_NAME}"
echo "  namespace:            ${NAMESPACE}"
echo "  clear_redis:          ${CLEAR_REDIS}"
echo "  clear_mongo:          ${CLEAR_MONGO}"
echo "  clear_shared_storage: ${CLEAR_SHARED_STORAGE}"
echo "  stop_running_analyses:${STOP_RUNNING_ANALYSES}"
echo

if [[ "${STOP_RUNNING_ANALYSES}" == "true" ]]; then
  web_pod="$(get_single_running_pod_by_label "app=web,release=${RELEASE_NAME}")"

  summary_json="$(active_analyses_summary "${web_pod}")"
  active_analyses="$(echo "${summary_json}" | jq -r '.active_analyses')"
  active_jobs="$(echo "${summary_json}" | jq -r '.active_jobs')"
  echo "Detected active analyses before reset: analyses=${active_analyses}, jobs=${active_jobs}"

  if [[ "${active_analyses}" != "0" || "${active_jobs}" != "0" ]]; then
    stop_json="$(request_stop_for_active_analyses "${web_pod}")"
    stop_requested="$(echo "${stop_json}" | jq -r '.stop_requested')"
    stop_failed="$(echo "${stop_json}" | jq -r '.stop_failed')"
    echo "Requested stop for active analyses: requested=${stop_requested}, failed=${stop_failed}"
  fi
fi

if [[ "${CLEAR_REDIS}" == "true" ]]; then
  redis_pod="$(get_single_running_pod_by_label "app=redis,release=${RELEASE_NAME}")"
  echo "Clearing Redis in pod ${redis_pod}..."
  kubectl -n "${NAMESPACE}" exec "${redis_pod}" -- sh -lc '
    PW="${REDIS_PASSWORD:-}"
    AUTH=""
    [ -n "$PW" ] && AUTH="-a $PW --no-auth-warning"
    redis-cli $AUTH FLUSHALL
  '
fi

if [[ "${CLEAR_MONGO}" == "true" ]]; then
  db_pod="$(get_single_running_pod_by_label "app=db,release=${RELEASE_NAME}")"
  echo "Dropping non-system Mongo databases in pod ${db_pod}..."
  kubectl -n "${NAMESPACE}" exec "${db_pod}" -- sh -lc '
    set -e
    if command -v mongosh >/dev/null 2>&1; then
      shell_bin="mongosh"
    elif command -v mongo >/dev/null 2>&1; then
      shell_bin="mongo"
    else
      echo "Neither mongosh nor mongo is available in db pod." >&2
      exit 1
    fi

    "$shell_bin" \
      --username "${MONGO_INITDB_ROOT_USERNAME}" \
      --password "${MONGO_INITDB_ROOT_PASSWORD}" \
      --authenticationDatabase admin \
      --quiet \
      --eval '"'"'
        const keep = ["admin", "config", "local"];
        db.getMongo().getDBNames().forEach((name) => {
          if (!keep.includes(name)) {
            print(`Dropping database: ${name}`);
            db.getSiblingDB(name).dropDatabase();
          }
        });
      '"'"'
  '
fi

if [[ "${CLEAR_SHARED_STORAGE}" == "true" ]]; then
  web_pod="$(get_single_running_pod_by_label "app=web,release=${RELEASE_NAME}")"
  echo "Clearing shared analysis files in pod ${web_pod}..."
  kubectl -n "${NAMESPACE}" exec "${web_pod}" -- bash -lc '
    set -euo pipefail
    if [[ ! -d /mnt/openstudio ]]; then
      echo "/mnt/openstudio is not mounted; cannot clear shared analysis files." >&2
      exit 1
    fi

    clear_tree_except_nfs_busy() {
      local root="$1"
      [[ -d "$root" ]] || return 0

      # Skip .nfs* placeholders because they are still open by a live process.
      # NFS removes them automatically after the open file handle is released.
      find "$root" -type f ! -name ".nfs*" -delete || true
      find "$root" -type l -delete || true
      find "$root" -depth -type d -empty -delete || true
    }

    while IFS= read -r analysis_dir; do
      clear_tree_except_nfs_busy "$analysis_dir"
    done < <(find /mnt/openstudio -mindepth 1 -maxdepth 1 -type d -name "analysis_*")

    if [[ -d /mnt/openstudio/server/assets/analyses ]]; then
      clear_tree_except_nfs_busy /mnt/openstudio/server/assets/analyses
    fi
    # Ensure the directory exists after clearing
    mkdir -p /mnt/openstudio/server/assets/analyses
  '
fi

echo "In-place data reset complete. Helm release '${RELEASE_NAME}' remains installed."
