#!/usr/bin/env bash
set -euo pipefail

# Destructive reset helper for OpenStudio Server.
# - Uninstalls the Helm release
# - Deletes persistent claims used by OpenStudio
# - Optionally reinstalls via scripts/install.sh
#
# Defaults:
#   RELEASE_NAME=openstudio-server
#   NAMESPACE=openstudio-server
#   CHART_PATH=./openstudio-server
#   REINSTALL=true
#
# Usage:
#   ./scripts/reset-fresh-start.sh --yes
#   PROVIDER=openstack ./scripts/reset-fresh-start.sh --yes
#   ./scripts/reset-fresh-start.sh --yes --no-reinstall
#   ./scripts/reset-fresh-start.sh --yes --release my-release --namespace my-ns

RELEASE_NAME="${RELEASE_NAME:-openstudio-server}"
NAMESPACE="${NAMESPACE:-openstudio-server}"
CHART_PATH="${CHART_PATH:-./openstudio-server}"
REINSTALL=true
ASSUME_YES=false
DELETE_NAMESPACE=true
UNINSTALL_WITH_HOOKS=false
TIMEOUT="${TIMEOUT:-20m}"
PROVIDER="${PROVIDER:-}"
NODEGROUP_LABEL_KEY="${NODEGROUP_LABEL_KEY:-}"
WEB_NODE_GROUP="${WEB_NODE_GROUP:-}"
WORKER_NODE_GROUP="${WORKER_NODE_GROUP:-}"
SECRET_MODE_INPUT="${SECRET_MODE:-existing}"
EXISTING_SECRET_NAME_INPUT="${EXISTING_SECRET_NAME:-openstudio-app-secrets}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SCRIPT="${SCRIPT_DIR}/install.sh"
BACKUP_DB_USERNAME=""
BACKUP_DB_PASSWORD=""
BACKUP_REDIS_PASSWORD=""
BACKUP_WEB_SECRET_KEY=""
INSTALL_START_TS=""

usage() {
  cat <<'EOF'
Usage: reset-fresh-start.sh --yes [options]

Destructively resets an OpenStudio deployment to a fresh start by uninstalling
the Helm release and deleting data PVCs.

Options:
  --yes               Required. Confirms destructive actions.
  --no-reinstall      Do not reinstall after cleanup.
  --keep-namespace    Do not delete the namespace after cleanup.
  --with-hooks        Run Helm uninstall hooks (default: disabled).
  --provider <name>   Provider for reinstall (aws|google|azure|openstack).
  --nodegroup-label-key <key>
                      Node-group label key override for scheduling guardrails.
  --web-node-group <value>
                      Web node-group value override for scheduling guardrails.
  --worker-node-group <value>
                      Worker node-group value override for scheduling guardrails.
  --release <name>    Helm release name (default: openstudio-server)
  --namespace <ns>    Kubernetes namespace (default: openstudio-server)
  --timeout <dur>     Helm/kubectl wait timeout (default: 20m)
  -h, --help          Show this help text.

Environment passed through to scripts/install.sh (when reinstalling):
  PROVIDER, VALUES_FILE, SECRET_MODE, EXISTING_SECRET_NAME,
  DB_USERNAME, DB_PASSWORD, REDIS_PASSWORD, WEB_SECRET_KEY,
  REGISTRY_PROFILE, REGISTRY_VALUES_FILE, REGISTRY_PULL_SECRET_NAME,
  WORKLOAD_SERVICEACCOUNT_NAME, HELM_DEBUG,
  NODEGROUP_LABEL_KEY, WEB_NODE_GROUP, WORKER_NODE_GROUP
EOF
}

duration_to_seconds() {
  local value="$1"
  if [[ "${value}" =~ ^([0-9]+)s$ ]]; then
    echo "${BASH_REMATCH[1]}"
    return 0
  fi
  if [[ "${value}" =~ ^([0-9]+)m$ ]]; then
    echo "$(( BASH_REMATCH[1] * 60 ))"
    return 0
  fi
  if [[ "${value}" =~ ^([0-9]+)h$ ]]; then
    echo "$(( BASH_REMATCH[1] * 3600 ))"
    return 0
  fi
  # Fallback when format is unexpected.
  echo 1200
}

run_filtered_stderr() {
  # Some clusters intermittently return HTTP/2 watch-stream INTERNAL_ERROR noise
  # from client-go reflectors. Filter that known non-actionable stderr chatter.
  "$@" 2> >(grep -Ev 'reflector\.go:664|unable to decode an event from the watch stream|stream ID [0-9]+; INTERNAL_ERROR' >&2)
}

detected_release_provider() {
  local release="$1"
  local namespace="$2"
  helm -n "${namespace}" get values "${release}" -a 2>/dev/null \
    | awk '
      /^global:[[:space:]]*$/ {in_global=1; next}
      in_global && /^[^[:space:]]/ {in_global=0}
      in_global && /^  provider:[[:space:]]*$/ {in_provider=1; next}
      in_provider && /^  [a-zA-Z0-9_-]+:[[:space:]]*$/ {in_provider=0}
      in_provider && /^    name:[[:space:]]*/ {
        sub(/^    name:[[:space:]]*/, "", $0)
        gsub(/"/, "", $0)
        print tolower($0)
        exit
      }
    '
}

detected_release_nodegroup_value() {
  local release="$1"
  local namespace="$2"
  local key_name="$3"
  helm -n "${namespace}" get values "${release}" -a 2>/dev/null \
    | awk -v target="${key_name}" '
      /^global:[[:space:]]*$/ {in_global=1; next}
      in_global && /^[^[:space:]]/ {in_global=0}
      in_global && /^  nodeGroups:[[:space:]]*$/ {in_nodegroups=1; next}
      in_nodegroups && /^  [a-zA-Z0-9_-]+:[[:space:]]*$/ {in_nodegroups=0}
      in_nodegroups && $0 ~ ("^    " target ":[[:space:]]*") {
        sub("^    " target ":[[:space:]]*", "", $0)
        gsub(/"/, "", $0)
        print $0
        exit
      }
    '
}

apply_nodegroup_defaults() {
  local provider="$1"
  if [[ -z "${NODEGROUP_LABEL_KEY}" ]]; then
    if [[ "${provider}" == "openstack" ]]; then
      NODEGROUP_LABEL_KEY="capi.stackhpc.com/node-group"
    else
      NODEGROUP_LABEL_KEY="nodegroup"
    fi
  fi
  if [[ -z "${WEB_NODE_GROUP}" ]]; then
    if [[ "${provider}" == "openstack" ]]; then
      WEB_NODE_GROUP="web"
    else
      WEB_NODE_GROUP="web-group"
    fi
  fi
  if [[ -z "${WORKER_NODE_GROUP}" ]]; then
    if [[ "${provider}" == "openstack" ]]; then
      WORKER_NODE_GROUP="worker"
    else
      WORKER_NODE_GROUP="worker-group"
    fi
  fi
}

validate_provider() {
  local provider="$1"
  case "${provider}" in
    aws|google|azure|openstack) return 0 ;;
    *)
      echo "Unsupported provider: ${provider}. Supported values: aws, google, azure, openstack." >&2
      return 1
      ;;
  esac
}

validate_nodegroup_compatibility() {
  local web_count worker_count
  web_count="$(kubectl get nodes -l "${NODEGROUP_LABEL_KEY}=${WEB_NODE_GROUP}" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  worker_count="$(kubectl get nodes -l "${NODEGROUP_LABEL_KEY}=${WORKER_NODE_GROUP}" --no-headers 2>/dev/null | wc -l | tr -d ' ')"

  if [[ "${web_count}" == "0" || "${worker_count}" == "0" ]]; then
    echo "Scheduling guardrail failed for provider=${PROVIDER}." >&2
    echo "Expected node labels:" >&2
    echo "  ${NODEGROUP_LABEL_KEY}=${WEB_NODE_GROUP} (web)" >&2
    echo "  ${NODEGROUP_LABEL_KEY}=${WORKER_NODE_GROUP} (worker)" >&2
    echo "Found node-group labels:" >&2
    kubectl get nodes -L "${NODEGROUP_LABEL_KEY}" >&2 || true
    return 1
  fi
  return 0
}

require_cluster_connectivity() {
  local attempts=8
  local sleep_seconds=5
  local attempt=1
  while (( attempt <= attempts )); do
    if kubectl --request-timeout=10s version >/dev/null 2>&1; then
      if kubectl --request-timeout=10s get --raw=/readyz >/dev/null 2>&1 \
        || kubectl --request-timeout=10s get --raw=/healthz >/dev/null 2>&1; then
        return 0
      fi
    fi
    echo "Kubernetes API preflight failed (attempt ${attempt}/${attempts}); retrying in ${sleep_seconds}s..." >&2
    sleep "${sleep_seconds}"
    attempt=$((attempt + 1))
  done

  echo "Kubernetes API is unreachable/unhealthy. Refusing reset to avoid partial destructive actions." >&2
  return 1
}

wait_for_pvcs_bound() {
  local timeout_seconds="$1"
  local -a names=("db" "redis" "nfs-pvc-data" "nfs-pvc")
  local deadline=$((SECONDS + timeout_seconds))
  while (( SECONDS < deadline )); do
    local all_bound=1
    for pvc in "${names[@]}"; do
      phase="$(kubectl -n "${NAMESPACE}" get pvc "${pvc}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
      if [[ "${phase}" != "Bound" ]]; then
        all_bound=0
        break
      fi
    done
    if (( all_bound == 1 )); then
      return 0
    fi
    # Fail fast when OpenStack quota blocks nfs-pvc-data provisioning.
    if [[ "${PROVIDER}" == "openstack" ]]; then
      local quota_error
      quota_error="$(
        kubectl -n "${NAMESPACE}" get events \
          --field-selector involvedObject.kind=PersistentVolumeClaim,involvedObject.name=nfs-pvc-data,reason=ProvisioningFailed,type=Warning \
          -o jsonpath='{range .items[*]}{.metadata.creationTimestamp}{"\t"}{.message}{"\n"}{end}' 2>/dev/null \
          | awk -v start="${INSTALL_START_TS}" '$1 >= start { $1=""; sub(/^\t/, ""); print }' \
          | grep -E 'VolumeSizeExceedsAvailableQuota|overLimit' \
          | tail -n 1 || true
      )"
      if [[ -n "${quota_error}" ]]; then
        echo "Detected OpenStack Cinder quota failure while provisioning nfs-pvc-data:" >&2
        echo "  ${quota_error}" >&2
        return 2
      fi
    fi
    sleep 2
  done
  return 1
}

wait_for_core_deployments_ready() {
  local timeout_seconds="$1"
  local -a names=(
    "openstudio-server-nfs-server-provisioner"
    "db"
    "redis"
    "rserve"
    "web"
    "web-background"
    "worker"
  )
  local deadline=$((SECONDS + timeout_seconds))
  while (( SECONDS < deadline )); do
    local all_ready=1
    for dep in "${names[@]}"; do
      local ready desired
      ready="$(kubectl -n "${NAMESPACE}" get deploy "${dep}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
      desired="$(kubectl -n "${NAMESPACE}" get deploy "${dep}" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"
      [[ -z "${ready}" ]] && ready=0
      [[ -z "${desired}" ]] && desired=0
      if [[ "${desired}" != "${ready}" ]]; then
        all_ready=0
        break
      fi
    done
    if (( all_ready == 1 )); then
      return 0
    fi
    sleep 3
  done
  return 1
}

cleanup_openstack_orphan_csi_volumes() {
  if [[ "${PROVIDER}" != "openstack" ]]; then
    return 0
  fi
  if ! command -v openstack >/dev/null 2>&1; then
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "Skipping OpenStack orphan-volume cleanup: jq not found." >&2
    return 0
  fi

  local orphan_rows
  orphan_rows="$(
    openstack volume list --long -f json 2>/dev/null \
      | jq -r --arg ns "${NAMESPACE}" '
          .[]
          | select((.Properties["csi.storage.k8s.io/pvc/namespace"] // "") == $ns)
          | select((.Properties["csi.storage.k8s.io/pvc/name"] // "") | test("^(db|redis|nfs-pvc-data|nfs-pvc)$"))
          | [(.ID // ""), (.Name // ""), (.Properties["csi.storage.k8s.io/pv/name"] // "")]
          | @tsv
        '
  )"

  [[ -z "${orphan_rows}" ]] && return 0

  while IFS=$'\t' read -r vol_id vol_name pv_name; do
    [[ -z "${vol_id}" ]] && continue
    # If the referenced PV still exists, this volume is still in active use by Kubernetes.
    if [[ -n "${pv_name}" ]] && kubectl get pv "${pv_name}" >/dev/null 2>&1; then
      continue
    fi

    echo "Cleaning orphan OpenStack CSI volume: ${vol_name:-<unnamed>} (${vol_id})" >&2

    local server_id
    while IFS= read -r server_id; do
      [[ -z "${server_id}" ]] && continue
      openstack server remove volume "${server_id}" "${vol_id}" >/dev/null 2>&1 || true
    done < <(
      openstack volume show "${vol_id}" -f json 2>/dev/null \
        | jq -r '.attachments[]?.server_id'
    )

    local attempt status
    for attempt in $(seq 1 20); do
      status="$(openstack volume show "${vol_id}" -f value -c status 2>/dev/null || true)"
      if [[ -z "${status}" || "${status}" == "available" ]]; then
        break
      fi
      sleep 3
    done

    openstack volume delete "${vol_id}" >/dev/null 2>&1 || true
  done <<< "${orphan_rows}"
}

generate_secret_value() {
  if command -v openssl >/dev/null 2>&1; then
    # Use URL-safe hex to avoid URI parsing issues in REDIS_URL and similar vars.
    openssl rand -hex 32
    return 0
  fi
  # Fallback without openssl: URL-safe alphanumeric only.
  LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 64
}

backup_existing_secret_if_present() {
  if [[ "${REINSTALL}" != "true" ]]; then
    return 0
  fi
  if [[ "${SECRET_MODE_INPUT}" != "existing" ]]; then
    return 0
  fi
  if kubectl -n "${NAMESPACE}" get secret "${EXISTING_SECRET_NAME_INPUT}" >/dev/null 2>&1; then
    BACKUP_DB_USERNAME="$(
      kubectl -n "${NAMESPACE}" get secret "${EXISTING_SECRET_NAME_INPUT}" -o jsonpath='{.data.db-username}' 2>/dev/null | base64 --decode || true
    )"
    BACKUP_DB_PASSWORD="$(
      kubectl -n "${NAMESPACE}" get secret "${EXISTING_SECRET_NAME_INPUT}" -o jsonpath='{.data.db-password}' 2>/dev/null | base64 --decode || true
    )"
    BACKUP_REDIS_PASSWORD="$(
      kubectl -n "${NAMESPACE}" get secret "${EXISTING_SECRET_NAME_INPUT}" -o jsonpath='{.data.redis-password}' 2>/dev/null | base64 --decode || true
    )"
    BACKUP_WEB_SECRET_KEY="$(
      kubectl -n "${NAMESPACE}" get secret "${EXISTING_SECRET_NAME_INPUT}" -o jsonpath='{.data.web-secret-key}' 2>/dev/null | base64 --decode || true
    )"
  fi
}

ensure_secret_exists_for_reinstall() {
  if [[ "${REINSTALL}" != "true" ]]; then
    return 0
  fi
  if [[ "${SECRET_MODE_INPUT}" != "existing" ]]; then
    return 0
  fi

  if kubectl -n "${NAMESPACE}" get secret "${EXISTING_SECRET_NAME_INPUT}" >/dev/null 2>&1; then
    return 0
  fi

  if [[ -n "${BACKUP_DB_USERNAME}" && -n "${BACKUP_DB_PASSWORD}" && -n "${BACKUP_REDIS_PASSWORD}" && -n "${BACKUP_WEB_SECRET_KEY}" ]]; then
    kubectl -n "${NAMESPACE}" create secret generic "${EXISTING_SECRET_NAME_INPUT}" \
      --from-literal=db-username="${BACKUP_DB_USERNAME}" \
      --from-literal=db-password="${BACKUP_DB_PASSWORD}" \
      --from-literal=redis-password="${BACKUP_REDIS_PASSWORD}" \
      --from-literal=web-secret-key="${BACKUP_WEB_SECRET_KEY}" >/dev/null
    return 0
  fi

  echo "Required secret '${EXISTING_SECRET_NAME_INPUT}' is missing in namespace '${NAMESPACE}'." >&2
  echo "Generating a new app secret automatically for fresh reinstall..." >&2
  local generated_db_username generated_db_password generated_redis_password generated_web_secret
  generated_db_username="openstudio"
  generated_db_password="$(generate_secret_value)"
  generated_redis_password="$(generate_secret_value)"
  generated_web_secret="$(generate_secret_value)"
  kubectl -n "${NAMESPACE}" create secret generic "${EXISTING_SECRET_NAME_INPUT}" \
    --from-literal=db-username="${generated_db_username}" \
    --from-literal=db-password="${generated_db_password}" \
    --from-literal=redis-password="${generated_redis_password}" \
    --from-literal=web-secret-key="${generated_web_secret}" >/dev/null
  echo "Created '${EXISTING_SECRET_NAME_INPUT}' with generated credentials." >&2
  return 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes)
      ASSUME_YES=true
      shift
      ;;
    --no-reinstall)
      REINSTALL=false
      shift
      ;;
    --keep-namespace)
      DELETE_NAMESPACE=false
      shift
      ;;
    --with-hooks)
      UNINSTALL_WITH_HOOKS=true
      shift
      ;;
    --provider)
      PROVIDER="${2:-}"
      shift 2
      ;;
    --nodegroup-label-key)
      NODEGROUP_LABEL_KEY="${2:-}"
      shift 2
      ;;
    --web-node-group)
      WEB_NODE_GROUP="${2:-}"
      shift 2
      ;;
    --worker-node-group)
      WORKER_NODE_GROUP="${2:-}"
      shift 2
      ;;
    --release)
      RELEASE_NAME="${2:-}"
      shift 2
      ;;
    --namespace)
      NAMESPACE="${2:-}"
      shift 2
      ;;
    --timeout)
      TIMEOUT="${2:-}"
      shift 2
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

if ! command -v helm >/dev/null 2>&1; then
  echo "helm is required." >&2
  exit 1
fi

if ! require_cluster_connectivity; then
  exit 1
fi

if [[ "${REINSTALL}" == "true" && ! -x "${INSTALL_SCRIPT}" ]]; then
  echo "Install helper not found or not executable: ${INSTALL_SCRIPT}" >&2
  exit 1
fi

RELEASE_EXISTS=false
if helm -n "${NAMESPACE}" status "${RELEASE_NAME}" >/dev/null 2>&1; then
  RELEASE_EXISTS=true
fi

if [[ -z "${PROVIDER}" && "${RELEASE_EXISTS}" == "true" ]]; then
  PROVIDER="$(detected_release_provider "${RELEASE_NAME}" "${NAMESPACE}")"
fi
if [[ -z "${NODEGROUP_LABEL_KEY}" && "${RELEASE_EXISTS}" == "true" ]]; then
  NODEGROUP_LABEL_KEY="$(detected_release_nodegroup_value "${RELEASE_NAME}" "${NAMESPACE}" "labelKey")"
fi
if [[ -z "${WEB_NODE_GROUP}" && "${RELEASE_EXISTS}" == "true" ]]; then
  WEB_NODE_GROUP="$(detected_release_nodegroup_value "${RELEASE_NAME}" "${NAMESPACE}" "web")"
fi
if [[ -z "${WORKER_NODE_GROUP}" && "${RELEASE_EXISTS}" == "true" ]]; then
  WORKER_NODE_GROUP="$(detected_release_nodegroup_value "${RELEASE_NAME}" "${NAMESPACE}" "worker")"
fi

if [[ "${REINSTALL}" == "true" && -z "${PROVIDER}" ]]; then
  echo "Provider could not be inferred. Set PROVIDER or use --provider." >&2
  exit 1
fi
if [[ -n "${PROVIDER}" ]]; then
  validate_provider "${PROVIDER}"
  apply_nodegroup_defaults "${PROVIDER}"
fi

echo "Starting fresh reset:"
echo "  release:   ${RELEASE_NAME}"
echo "  namespace: ${NAMESPACE}"
echo "  reinstall: ${REINSTALL}"
echo "  hooks:     ${UNINSTALL_WITH_HOOKS}"
if [[ -n "${VALUES_FILE:-}" ]]; then
  echo "  values:    ${VALUES_FILE}"
fi
if [[ -n "${PROVIDER}" ]]; then
  echo "  provider:  ${PROVIDER}"
  echo "  nodegroup: ${NODEGROUP_LABEL_KEY} (web=${WEB_NODE_GROUP}, worker=${WORKER_NODE_GROUP})"
fi
echo

backup_existing_secret_if_present

# Ensure release workloads are removed first.
if [[ "${RELEASE_EXISTS}" == "true" ]]; then
  if [[ "${UNINSTALL_WITH_HOOKS}" == "true" ]]; then
    if ! run_filtered_stderr helm uninstall "${RELEASE_NAME}" -n "${NAMESPACE}" --timeout "${TIMEOUT}"; then
      echo "Helm uninstall with hooks failed; retrying without hooks to unblock fresh reset..." >&2
      run_filtered_stderr helm uninstall "${RELEASE_NAME}" -n "${NAMESPACE}" --no-hooks --timeout "${TIMEOUT}" || true
    fi
  else
    run_filtered_stderr helm uninstall "${RELEASE_NAME}" -n "${NAMESPACE}" --no-hooks --timeout "${TIMEOUT}" || true
  fi

  if helm -n "${NAMESPACE}" status "${RELEASE_NAME}" >/dev/null 2>&1; then
    echo "Release ${RELEASE_NAME} still exists after uninstall attempts; aborting reset." >&2
    exit 1
  fi
else
  echo "Helm release ${RELEASE_NAME} not found in ${NAMESPACE}; continuing with cleanup."
fi

# Remove leftover workload resources with graceful termination first.
kubectl -n "${NAMESPACE}" delete pods --all --ignore-not-found=true --wait=false 2>/dev/null || true
kubectl -n "${NAMESPACE}" delete jobs --all --ignore-not-found=true --wait=false 2>/dev/null || true
kubectl -n "${NAMESPACE}" delete cronjobs --all --ignore-not-found=true --wait=false 2>/dev/null || true

# Delete persistent claims that carry all runtime data.
PVC_NAMES=(db redis nfs-pvc nfs-pvc-data)
PV_NAMES=()

while IFS= read -r pv_name; do
  [[ -z "${pv_name}" ]] && continue
  PV_NAMES+=("${pv_name}")
done < <(
  kubectl get pv -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.claimRef.namespace}{"\t"}{.spec.claimRef.name}{"\n"}{end}' \
    | awk -v ns="${NAMESPACE}" '
        $2 == ns && ($3 == "db" || $3 == "redis" || $3 == "nfs-pvc" || $3 == "nfs-pvc-data") { print $1 }
      '
)

for pvc in "${PVC_NAMES[@]}"; do
  kubectl -n "${NAMESPACE}" delete pvc "${pvc}" --ignore-not-found=true --wait=false 2>/dev/null || true
done

timeout_seconds="$(duration_to_seconds "${TIMEOUT}")"
deadline=$((SECONDS + timeout_seconds))
while (( SECONDS < deadline )); do
  remaining=0
  for pvc in "${PVC_NAMES[@]}"; do
    if kubectl -n "${NAMESPACE}" get pvc "${pvc}" >/dev/null 2>&1; then
      remaining=$((remaining + 1))
      if kubectl -n "${NAMESPACE}" get pvc "${pvc}" -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null | grep -q .; then
        echo "Stripping finalizers from stuck PVC: ${pvc}" >&2
        kubectl -n "${NAMESPACE}" patch pvc "${pvc}" -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
      fi
    fi
  done
  if (( remaining == 0 )); then
    break
  fi
  sleep 2
done

remaining_pvcs=0
for pvc in "${PVC_NAMES[@]}"; do
  if kubectl -n "${NAMESPACE}" get pvc "${pvc}" >/dev/null 2>&1; then
    remaining_pvcs=$((remaining_pvcs + 1))
  fi
done
if (( remaining_pvcs > 0 )); then
  echo "Timed out waiting for PVC deletion; refusing to reinstall with stale claims." >&2
  exit 1
fi

# Delete only PVs that were previously bound to reset target PVCs.
for pv_name in "${PV_NAMES[@]}"; do
  kubectl delete pv "${pv_name}" --ignore-not-found=true --wait=false || true
done

if (( ${#PV_NAMES[@]} > 0 )); then
  pv_deadline=$((SECONDS + timeout_seconds))
  while (( SECONDS < pv_deadline )); do
    remaining=0
    for pv_name in "${PV_NAMES[@]}"; do
      if kubectl get pv "${pv_name}" >/dev/null 2>&1; then
        remaining=$((remaining + 1))
        if kubectl get pv "${pv_name}" -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null | grep -q .; then
          kubectl patch pv "${pv_name}" -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
        fi
      fi
    done
    if (( remaining == 0 )); then
      break
    fi
    sleep 2
  done
fi

cleanup_openstack_orphan_csi_volumes

if [[ "${REINSTALL}" == "true" ]]; then
  if ! validate_nodegroup_compatibility; then
    echo "Aborting reinstall: selected provider/nodegroup mapping is incompatible with current cluster labels." >&2
    exit 1
  fi
  if ! ensure_secret_exists_for_reinstall; then
    exit 1
  fi
  # Namespace must exist for reinstall; skip deletion.
  INSTALL_START_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  run_filtered_stderr env PROVIDER="${PROVIDER}" RELEASE_NAME="${RELEASE_NAME}" NAMESPACE="${NAMESPACE}" CHART_PATH="${CHART_PATH}" "${INSTALL_SCRIPT}"
  pvc_wait_rc=0
  if ! wait_for_pvcs_bound "${timeout_seconds}"; then
    pvc_wait_rc=$?
  fi
  if [[ "${pvc_wait_rc}" == "2" ]]; then
    echo "Post-reinstall validation failed early: nfs-pvc-data provisioning hit Cinder quota limits." >&2
    echo "Set smaller storage requests in a values file and rerun reset (for example tune nfs-server-provisioner.persistence.size and nfs_pvc.storage)." >&2
    kubectl -n "${NAMESPACE}" get pvc >&2 || true
    kubectl -n "${NAMESPACE}" get events --sort-by=.metadata.creationTimestamp | tail -n 120 >&2 || true
    exit 1
  fi
  if [[ "${pvc_wait_rc}" != "0" ]]; then
    echo "Post-reinstall validation failed: core PVCs did not reach Bound state in ${TIMEOUT}." >&2
    kubectl -n "${NAMESPACE}" get pvc >&2 || true
    kubectl -n "${NAMESPACE}" get events --sort-by=.metadata.creationTimestamp | tail -n 120 >&2 || true
    exit 1
  fi
  if ! wait_for_core_deployments_ready "${timeout_seconds}"; then
    echo "Post-reinstall validation failed: core deployments did not become ready in ${TIMEOUT}." >&2
    kubectl -n "${NAMESPACE}" get deploy,pods >&2 || true
    kubectl -n "${NAMESPACE}" get events --sort-by=.metadata.creationTimestamp | tail -n 120 >&2 || true
    exit 1
  fi
elif [[ "${DELETE_NAMESPACE}" == "true" ]]; then
  echo "Deleting namespace ${NAMESPACE}..."
  kubectl delete namespace "${NAMESPACE}" --ignore-not-found=true --wait=false 2>/dev/null || true
  echo "Recreating empty namespace ${NAMESPACE} for next install..."
  kubectl create namespace "${NAMESPACE}" 2>/dev/null || true
fi

echo "Fresh reset complete."
