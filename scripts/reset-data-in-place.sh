#!/usr/bin/env bash
set -euo pipefail

# Destructive in-place data reset helper for OpenStudio Server.
# - Keeps the Helm release installed
# - Clears Redis keys
# - Drops all non-system Mongo databases
# - Removes shared analysis artifacts from /mnt/openstudio
# - Restarts worker pods so no in-flight extraction can repopulate cleared directories
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
RESTART_WORKERS=true

usage() {
  cat <<'EOF'
Usage: reset-data-in-place.sh --yes [options]

Destructively clears OpenStudio app data WITHOUT uninstalling the Helm release.

What it clears by default:
  - Redis keys (FLUSHALL)
  - Mongo non-system databases (drops all except admin/config/local)
  - Shared analysis files on NFS (/mnt/openstudio/analysis_* and /mnt/openstudio/server/assets/analyses/*)
  - Stops active analyses before clearing
  - Restarts worker pods after clearing so no in-flight extraction repopulates cleared directories

Options:
  --yes                     Required. Confirms destructive actions.
  --namespace <ns>          Kubernetes namespace (default: openstudio-server)
  --release <name>          Helm release name (default: openstudio-server)
  --no-clear-redis          Skip Redis FLUSHALL.
  --no-clear-mongo          Skip Mongo database drops.
  --no-clear-shared-storage Skip shared storage file deletion.
  --no-stop-running-analyses
                            Skip checking/stopping active analyses before clearing.
  --no-restart-workers      Skip restarting worker pods after clearing shared storage.
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
    --no-restart-workers)
      RESTART_WORKERS=false
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

check_and_stop_active_analyses() {
  local web_pod=$1
  # Single Rails environment load: count active work AND issue stop requests in one pass.
  kubectl -n "${NAMESPACE}" exec "${web_pod}" -c web -- bash -lc "
    cd /opt/openstudio/server
    bundle exec rails runner '
      require %q(json)
      result = {active_analyses: 0, active_jobs: 0, stop_requested: 0, stop_failed: 0}
      active = Analysis.where(:status.in => [%q(started), %q(queued)])
      result[:active_analyses] = active.count
      result[:active_jobs] = Job.where(:status.in => [%q(started), %q(queued)]).count
      active.each do |analysis|
        begin
          analysis.run_flag = false if analysis.respond_to?(:run_flag)
          analysis.save! if analysis.changed?
          analysis.run_analysis(false, %q(stop), {})
          result[:stop_requested] += 1
        rescue StandardError
          result[:stop_failed] += 1
        end
      end
      puts JSON.generate(result)
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
echo "  restart_workers:      ${RESTART_WORKERS}"
echo

if [[ "${STOP_RUNNING_ANALYSES}" == "true" ]]; then
  web_pod="$(get_single_running_pod_by_label "app=web,release=${RELEASE_NAME}")"

  # Single Rails invocation: counts active work and issues stop requests in one pass.
  result_json="$(check_and_stop_active_analyses "${web_pod}")"
  active_analyses="$(echo "${result_json}" | jq -r '.active_analyses')"
  active_jobs="$(echo "${result_json}" | jq -r '.active_jobs')"
  echo "Detected active analyses before reset: analyses=${active_analyses}, jobs=${active_jobs}"

  if [[ "${active_analyses}" != "0" || "${active_jobs}" != "0" ]]; then
    stop_requested="$(echo "${result_json}" | jq -r '.stop_requested')"
    stop_failed="$(echo "${result_json}" | jq -r '.stop_failed')"
    echo "Requested stop for active analyses: requested=${stop_requested}, failed=${stop_failed}"
  fi
fi

# Restart workers BEFORE clearing storage so that no worker pod holds open file
# handles on the NFS volume when we attempt deletion.  On NFS, rm -rf fails with
# "Directory not empty" when another process has the directory open; killing the
# workers first closes all those handles.
if [[ "${RESTART_WORKERS}" == "true" ]]; then
  echo "Restarting worker pods before storage clear to release open NFS file handles..."
  # Resolve deployment names by following the pod → ReplicaSet → Deployment owner
  # chain.  Deployments may not carry the `release` label themselves, so we cannot
  # filter deployments directly; instead we filter pods (which do carry it) and
  # walk upward through ownerReferences.
  worker_deploys=""
  while IFS= read -r rs_name; do
    [[ -z "${rs_name}" ]] && continue
    deploy_name="$(kubectl -n "${NAMESPACE}" get replicaset "${rs_name}" \
      -o jsonpath='{.metadata.ownerReferences[0].name}' 2>/dev/null || true)"
    [[ -n "${deploy_name}" ]] && worker_deploys+="${deploy_name}"$'\n'
  done < <(kubectl -n "${NAMESPACE}" get pods -l "app=worker,release=${RELEASE_NAME}" \
    --no-headers -o custom-columns=":metadata.ownerReferences[0].name" 2>/dev/null \
    | sort -u)
  worker_deploys="$(echo "${worker_deploys}" | sort -u | grep -v '^$' || true)"

  # Lock any HPA targeting worker deployments at minReplicas so it cannot
  # create new pods to replace force-deleted ones during the reset.  We save
  # the original min/max and restore them at the end of the script.
  worker_hpa=""
  hpa_orig_min=""
  hpa_orig_max=""
  if [[ -n "${worker_deploys}" ]]; then
    first_deploy="$(echo "${worker_deploys}" | head -1)"
    worker_hpa="$(kubectl -n "${NAMESPACE}" get hpa --no-headers 2>/dev/null \
      | awk -v d="${first_deploy}" 'split($2,ref,"/") && ref[2]==d {print $1}' | head -1 || true)"
  fi
  if [[ -n "${worker_hpa}" ]]; then
    hpa_orig_min="$(kubectl -n "${NAMESPACE}" get hpa "${worker_hpa}" \
      -o jsonpath='{.spec.minReplicas}' 2>/dev/null || true)"
    hpa_orig_max="$(kubectl -n "${NAMESPACE}" get hpa "${worker_hpa}" \
      -o jsonpath='{.spec.maxReplicas}' 2>/dev/null || true)"
    echo "Locking HPA ${worker_hpa} at minReplicas=${hpa_orig_min} (was max=${hpa_orig_max}) to prevent scale-up during reset..."
    kubectl -n "${NAMESPACE}" patch hpa "${worker_hpa}" \
      --type=merge -p "{\"spec\":{\"maxReplicas\":${hpa_orig_min:-1}}}"
    # Also scale the deployment directly to minReplicas now.  The HPA reconciliation
    # loop runs asynchronously (every ~15-30s), so patching the HPA alone does not
    # take effect before the rollout restart; we would roll out at the stale replica
    # count and end up with too many pods after the reset.
    while IFS= read -r deploy; do
      echo "Scaling deployment/${deploy} to ${hpa_orig_min:-1} replicas..."
      kubectl -n "${NAMESPACE}" scale deployment/"${deploy}" --replicas="${hpa_orig_min:-1}"
    done <<< "${worker_deploys}"
  else
    echo "No HPA found for worker deployments — skipping HPA lock."
  fi

  if [[ -z "${worker_deploys}" ]]; then
    echo "WARNING: could not resolve worker deployment names; skipping rollout restart." >&2
  else
    while IFS= read -r deploy; do
      kubectl -n "${NAMESPACE}" rollout restart deployment/"${deploy}"
    done <<< "${worker_deploys}"
    echo "Waiting for worker rollout to complete..."
    while IFS= read -r deploy; do
      kubectl -n "${NAMESPACE}" rollout status deployment/"${deploy}" --timeout=120s
    done <<< "${worker_deploys}"
  fi

  # rollout status returns as soon as desired replicas are healthy, but old pods
  # can remain in Terminating and still hold NFS handles or pick up new jobs.
  # Force-delete Terminating pods immediately, then poll until none remain.
  # Re-issue force-delete on each poll tick in case new pods entered Terminating
  # after the initial pass (e.g., from an overlapping previous rollout).
  echo "Force-deleting any Terminating worker pods..."
  terminating_wait=0
  terminating_timeout=120
  while true; do
    terminating_pods="$(kubectl -n "${NAMESPACE}" get pods -l "app=worker,release=${RELEASE_NAME}" \
      --no-headers 2>/dev/null | awk '$3=="Terminating" {print $1}' || true)"
    [[ -z "${terminating_pods}" ]] && break
    echo "${terminating_pods}" | xargs kubectl -n "${NAMESPACE}" delete pod --grace-period=0 --force --ignore-not-found 2>&1 | grep -v "^Warning:\|force deleted" || true
    if [[ "${terminating_wait}" -ge "${terminating_timeout}" ]]; then
      echo "WARNING: timed out after ${terminating_timeout}s waiting for Terminating pods to exit." >&2
      echo "  The following pods are still Terminating:" >&2
      echo "${terminating_pods}" >&2
      echo "  Proceeding anyway — storage clear may still encounter open file handles." >&2
      break
    fi
    sleep 5
    terminating_wait=$(( terminating_wait + 5 ))
  done
  if [[ "${terminating_wait}" -lt "${terminating_timeout}" && -z "$(kubectl -n "${NAMESPACE}" get pods -l "app=worker,release=${RELEASE_NAME}" --no-headers 2>/dev/null | awk '$3=="Terminating" {print $1}' || true)" ]]; then
    echo "All worker pods are Running — no Terminating pods remain."
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
  kubectl -n "${NAMESPACE}" exec "${web_pod}" -c web -- bash -lc '
    set -euo pipefail
    if [[ ! -d /mnt/openstudio ]]; then
      echo "/mnt/openstudio is not mounted; cannot clear shared analysis files." >&2
      exit 1
    fi

    # Delete files depth-first before attempting directory removal.  A plain
    # "rm -rf <dir>" can fail on NFS with "Directory not empty" even after all
    # child files are gone, because the NFS client may leave .nfsXXXX temporary
    # files behind for recently-closed handles.  The two-pass approach (files
    # first, then empty directories) is more reliable on NFS.
    find /mnt/openstudio -mindepth 1 -maxdepth 1 -type d -name "analysis_*" | while read -r dir; do
      find "$dir" -depth -ignore_readdir_race -type f -delete 2>/dev/null || true
      find "$dir" -depth -ignore_readdir_race -type d -empty -delete 2>/dev/null || true
      # Final fallback: if any directory still exists (e.g. NFS .nfs* temp files),
      # force-remove it; errors here are reported but do not abort the script.
      rm -rf "$dir" || echo "WARNING: could not fully remove $dir" >&2
    done

    find /mnt/openstudio/server/assets/analyses -depth -type f -delete 2>/dev/null || true
    find /mnt/openstudio/server/assets/analyses -depth -type d -empty -delete 2>/dev/null || true
    rm -rf /mnt/openstudio/server/assets/analyses || echo "WARNING: could not fully remove server/assets/analyses" >&2
    # Do NOT recreate this directory as root — the Passenger app process runs as
    # 'nobody' and would get Errno::EACCES on a root-owned 755 dir (→ HTTP 500).
    # Paperclip recreates it with correct ownership on the first upload.
  '
fi

# Verify no analysis directories remain on the shared volume.
if [[ "${CLEAR_SHARED_STORAGE}" == "true" ]]; then
  web_pod="$(get_single_running_pod_by_label "app=web,release=${RELEASE_NAME}")"
  echo "Verifying shared volume is clean..."
  stale="$(kubectl -n "${NAMESPACE}" exec "${web_pod}" -c web -- bash -lc \
    'find /mnt/openstudio -mindepth 1 -maxdepth 1 -type d -name "analysis_*" 2>/dev/null || true')"
  if [[ -n "${stale}" ]]; then
    echo "WARNING: stale analysis directories remain on the volume:" >&2
    echo "${stale}" >&2
  else
    echo "Shared volume is clean — no stale analysis directories found."
  fi
fi

# Restore HPA to its original min/max now that storage is clean and new jobs
# can safely run.  The HPA will scale workers back up as analyses are submitted.
if [[ -n "${worker_hpa:-}" && -n "${hpa_orig_min:-}" && -n "${hpa_orig_max:-}" ]]; then
  echo "Restoring HPA ${worker_hpa} to min=${hpa_orig_min} max=${hpa_orig_max}..."
  kubectl -n "${NAMESPACE}" patch hpa "${worker_hpa}" \
    --type=merge -p "{\"spec\":{\"minReplicas\":${hpa_orig_min},\"maxReplicas\":${hpa_orig_max}}}"
fi

echo "In-place data reset complete. Helm release '${RELEASE_NAME}' remains installed."
