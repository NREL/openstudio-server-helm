#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   PROVIDER=openstack ./scripts/install.sh
#
# Optional environment variables:
#   RELEASE_NAME (default: openstudio-server)
#   NAMESPACE (default: openstudio-server)
#   CHART_PATH (default: ./openstudio-server)
#   HELM_DEBUG (default: true)
#   VALUES_FILE (optional; extra values override file)
#   SECRET_MODE (default: existing; supported: existing, create)
#   EXISTING_SECRET_NAME (default: openstudio-app-secrets; used when SECRET_MODE=existing)
#   DB_USERNAME, DB_PASSWORD, REDIS_PASSWORD, WEB_SECRET_KEY (required when SECRET_MODE=create)
#   REGISTRY_PROFILE (default: false; when true include REGISTRY_VALUES_FILE)
#   REGISTRY_VALUES_FILE (default: ./openstudio-server/values.registry-live.yaml)
#   REGISTRY_PULL_SECRET_NAME (optional; sets global/serviceAccount imagePullSecrets[0])
#     Not required for the tracked Pulp registry profile (node-level auth).
#   WORKLOAD_SERVICEACCOUNT_NAME (default: openstudio-workload; used with REGISTRY_PULL_SECRET_NAME)
PROVIDER="${PROVIDER:-aws}"
RELEASE_NAME="${RELEASE_NAME:-openstudio-server}"
NAMESPACE="${NAMESPACE:-openstudio-server}"
CHART_PATH="${CHART_PATH:-./openstudio-server}"
HELM_DEBUG="${HELM_DEBUG:-true}"
VALUES_FILE="${VALUES_FILE:-}"
SECRET_MODE="${SECRET_MODE:-existing}"
EXISTING_SECRET_NAME="${EXISTING_SECRET_NAME:-openstudio-app-secrets}"
REGISTRY_PROFILE="${REGISTRY_PROFILE:-false}"
REGISTRY_VALUES_FILE="${REGISTRY_VALUES_FILE:-./openstudio-server/values.registry-live.yaml}"
REGISTRY_PULL_SECRET_NAME="${REGISTRY_PULL_SECRET_NAME:-}"
WORKLOAD_SERVICEACCOUNT_NAME="${WORKLOAD_SERVICEACCOUNT_NAME:-openstudio-workload}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRET_VALIDATOR="${SCRIPT_DIR}/validate-app-secret.sh"
TMP_SECRET_VALUES_FILE=""

cleanup() {
  if [[ -n "${TMP_SECRET_VALUES_FILE}" && -f "${TMP_SECRET_VALUES_FILE}" ]]; then
    rm -f "${TMP_SECRET_VALUES_FILE}"
  fi
}

yaml_single_quote() {
  printf "%s" "$1" | sed "s/'/''/g"
}

trap cleanup EXIT

case "${PROVIDER}" in
  aws|google|azure|openstack) ;;
  *)
    echo "Unsupported PROVIDER=${PROVIDER}. Supported values: aws, google, azure, openstack." >&2
    exit 1
    ;;
esac

HELM_ARGS=()
if [[ "${HELM_DEBUG}" == "true" ]]; then
  HELM_ARGS+=(--debug)
fi

HELM_ARGS+=(--namespace "${NAMESPACE}" --create-namespace)
HELM_ARGS+=(--set "global.provider.name=${PROVIDER}")

if [[ -n "${VALUES_FILE}" ]]; then
  if [[ ! -f "${VALUES_FILE}" ]]; then
    echo "VALUES_FILE does not exist: ${VALUES_FILE}" >&2
    exit 1
  fi
  HELM_ARGS+=(--values "${VALUES_FILE}")
fi

if [[ "${REGISTRY_PROFILE}" == "true" ]]; then
  if [[ ! -f "${REGISTRY_VALUES_FILE}" ]]; then
    echo "REGISTRY_VALUES_FILE does not exist: ${REGISTRY_VALUES_FILE}" >&2
    exit 1
  fi
  HELM_ARGS+=(--values "${REGISTRY_VALUES_FILE}")
fi

if [[ -n "${REGISTRY_PULL_SECRET_NAME}" ]]; then
  HELM_ARGS+=(
    --set-string "global.imagePullSecrets[0]=${REGISTRY_PULL_SECRET_NAME}"
    --set "serviceAccount.create=true"
    --set-string "serviceAccount.name=${WORKLOAD_SERVICEACCOUNT_NAME}"
    --set-string "serviceAccount.imagePullSecrets[0]=${REGISTRY_PULL_SECRET_NAME}"
  )
fi

case "${SECRET_MODE}" in
  existing)
    if [[ ! -x "${SECRET_VALIDATOR}" ]]; then
      echo "Secret validator script is missing or not executable: ${SECRET_VALIDATOR}" >&2
      exit 1
    fi

    if ! command -v kubectl >/dev/null 2>&1; then
      echo "kubectl is required to validate existing secrets." >&2
      exit 1
    fi

    if ! kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1; then
      kubectl create namespace "${NAMESPACE}" >/dev/null
    fi

    "${SECRET_VALIDATOR}" --namespace "${NAMESPACE}" --secret-name "${EXISTING_SECRET_NAME}"

    HELM_ARGS+=(
      --set "secrets.existingSecret=${EXISTING_SECRET_NAME}"
      --set "secrets.create=false"
      --set "secrets.validateExistingSecret=true"
    )
    ;;
  create)
    for env_var in DB_USERNAME DB_PASSWORD REDIS_PASSWORD WEB_SECRET_KEY; do
      if [[ -z "${!env_var:-}" ]]; then
        echo "Missing required environment variable for SECRET_MODE=create: ${env_var}" >&2
        exit 1
      fi
    done

    TMP_SECRET_VALUES_FILE="$(mktemp)"
    chmod 600 "${TMP_SECRET_VALUES_FILE}"
    cat > "${TMP_SECRET_VALUES_FILE}" <<EOF
secrets:
  existingSecret: ""
  create: true
db:
  username: '$(yaml_single_quote "${DB_USERNAME}")'
  password: '$(yaml_single_quote "${DB_PASSWORD}")'
redis:
  password: '$(yaml_single_quote "${REDIS_PASSWORD}")'
web:
  secret_key_value: '$(yaml_single_quote "${WEB_SECRET_KEY}")'
EOF

    HELM_ARGS+=(
      --set "secrets.existingSecret="
      --set "secrets.create=true"
      --values "${TMP_SECRET_VALUES_FILE}"
    )
    ;;
  *)
    echo "Unsupported SECRET_MODE=${SECRET_MODE}. Supported values: existing, create." >&2
    exit 1
    ;;
esac

helm upgrade --install "${RELEASE_NAME}" "${CHART_PATH}" "${HELM_ARGS[@]}"
