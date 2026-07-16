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
TIMEOUT="${TIMEOUT:-20m}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SCRIPT="${SCRIPT_DIR}/install.sh"

usage() {
  cat <<'EOF'
Usage: reset-fresh-start.sh --yes [options]

Destructively resets an OpenStudio deployment to a fresh start by uninstalling
the Helm release and deleting data PVCs.

Options:
  --yes               Required. Confirms destructive actions.
  --no-reinstall      Do not reinstall after cleanup.
  --keep-namespace    Do not delete the namespace after cleanup.
  --release <name>    Helm release name (default: openstudio-server)
  --namespace <ns>    Kubernetes namespace (default: openstudio-server)
  --timeout <dur>     Helm/kubectl wait timeout (default: 20m)
  -h, --help          Show this help text.

Environment passed through to scripts/install.sh (when reinstalling):
  PROVIDER, VALUES_FILE, SECRET_MODE, EXISTING_SECRET_NAME,
  DB_USERNAME, DB_PASSWORD, REDIS_PASSWORD, WEB_SECRET_KEY,
  REGISTRY_PROFILE, REGISTRY_VALUES_FILE, REGISTRY_PULL_SECRET_NAME,
  WORKLOAD_SERVICEACCOUNT_NAME, HELM_DEBUG
EOF
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

if [[ "${REINSTALL}" == "true" && ! -x "${INSTALL_SCRIPT}" ]]; then
  echo "Install helper not found or not executable: ${INSTALL_SCRIPT}" >&2
  exit 1
fi

echo "Starting fresh reset:"
echo "  release:   ${RELEASE_NAME}"
echo "  namespace: ${NAMESPACE}"
echo "  reinstall: ${REINSTALL}"
echo

# Ensure release workloads are removed first.
if helm -n "${NAMESPACE}" status "${RELEASE_NAME}" >/dev/null 2>&1; then
  if ! helm uninstall "${RELEASE_NAME}" -n "${NAMESPACE}" --wait --timeout "${TIMEOUT}"; then
    echo "Helm uninstall with hooks failed; retrying without hooks to unblock fresh reset..." >&2
    helm uninstall "${RELEASE_NAME}" -n "${NAMESPACE}" --no-hooks --wait --timeout "${TIMEOUT}"
  fi
else
  echo "Helm release ${RELEASE_NAME} not found in ${NAMESPACE}; continuing with cleanup."
fi

# Force-delete any stuck pods, jobs, and cronjobs left behind.
kubectl -n "${NAMESPACE}" delete pods --all --force --grace-period=0 2>/dev/null || true
kubectl -n "${NAMESPACE}" delete jobs --all --force --grace-period=0 2>/dev/null || true
kubectl -n "${NAMESPACE}" delete cronjobs --all --force --grace-period=0 2>/dev/null || true

# Delete persistent claims that carry all runtime data.
PVC_NAMES=(db redis nfs-pvc nfs-pvc-data)
for pvc in "${PVC_NAMES[@]}"; do
  kubectl -n "${NAMESPACE}" delete pvc "${pvc}" --ignore-not-found=true 2>/dev/null || true
done

for pvc in "${PVC_NAMES[@]}"; do
  kubectl -n "${NAMESPACE}" wait --for=delete "pvc/${pvc}" --timeout="${TIMEOUT}" 2>/dev/null || true
done

# If any PVCs are stuck in Terminating, strip their finalizers to unblock deletion.
while IFS= read -r stuck_pvc; do
  [[ -z "${stuck_pvc}" ]] && continue
  echo "Stripping finalizers from stuck PVC: ${stuck_pvc}" >&2
  kubectl -n "${NAMESPACE}" patch pvc "${stuck_pvc}" -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
done < <(kubectl -n "${NAMESPACE}" get pvc -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.deletionTimestamp}{"\n"}{end}' \
  | awk '$2 != "" { print $1 }')

# Delete ALL PVs bound to this namespace (catches anything the PVC list missed).
while IFS= read -r pv_name; do
  [[ -z "${pv_name}" ]] && continue
  kubectl delete pv "${pv_name}" --ignore-not-found=true || true
done < <(
  kubectl get pv -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.claimRef.namespace}{"\n"}{end}' \
    | awk -v ns="${NAMESPACE}" '$2 == ns { print $1 }'
)

if [[ "${REINSTALL}" == "true" ]]; then
  # Namespace must exist for reinstall; skip deletion.
  RELEASE_NAME="${RELEASE_NAME}" NAMESPACE="${NAMESPACE}" CHART_PATH="${CHART_PATH}" "${INSTALL_SCRIPT}"
elif [[ "${DELETE_NAMESPACE}" == "true" ]]; then
  echo "Deleting namespace ${NAMESPACE}..."
  kubectl delete namespace "${NAMESPACE}" --ignore-not-found=true 2>/dev/null || true
  echo "Recreating empty namespace ${NAMESPACE} for next install..."
  kubectl create namespace "${NAMESPACE}" 2>/dev/null || true
fi

echo "Fresh reset complete."
