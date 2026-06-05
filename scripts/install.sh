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
#   SECRET_MODE (default: existing; supported: existing, create)
#   EXISTING_SECRET_NAME (default: openstudio-app-secrets; used when SECRET_MODE=existing)
#   DB_USERNAME, DB_PASSWORD, REDIS_PASSWORD, WEB_SECRET_KEY (required when SECRET_MODE=create)
PROVIDER="${PROVIDER:-aws}"
RELEASE_NAME="${RELEASE_NAME:-openstudio-server}"
NAMESPACE="${NAMESPACE:-openstudio-server}"
CHART_PATH="${CHART_PATH:-./openstudio-server}"
HELM_DEBUG="${HELM_DEBUG:-true}"
SECRET_MODE="${SECRET_MODE:-existing}"
EXISTING_SECRET_NAME="${EXISTING_SECRET_NAME:-openstudio-app-secrets}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRET_VALIDATOR="${SCRIPT_DIR}/validate-app-secret.sh"

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

case "${SECRET_MODE}" in
  existing)
    if [[ ! -x "${SECRET_VALIDATOR}" ]]; then
      echo "Secret validator script is missing or not executable: ${SECRET_VALIDATOR}" >&2
      exit 1
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

    HELM_ARGS+=(
      --set "secrets.existingSecret="
      --set "secrets.create=true"
      --set "db.username=${DB_USERNAME}"
      --set "db.password=${DB_PASSWORD}"
      --set "redis.password=${REDIS_PASSWORD}"
      --set "web.secret_key_value=${WEB_SECRET_KEY}"
    )
    ;;
  *)
    echo "Unsupported SECRET_MODE=${SECRET_MODE}. Supported values: existing, create." >&2
    exit 1
    ;;
esac

helm upgrade --install "${RELEASE_NAME}" "${CHART_PATH}" "${HELM_ARGS[@]}"
