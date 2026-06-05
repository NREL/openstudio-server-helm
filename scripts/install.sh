#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   PROVIDER=openstack ./scripts/install.sh
#
# Optional environment variables:
#   RELEASE_NAME (default: openstudio-server)
#   CHART_PATH (default: ./openstudio-server)
#   HELM_DEBUG (default: true)
PROVIDER="${PROVIDER:-aws}"
RELEASE_NAME="${RELEASE_NAME:-openstudio-server}"
CHART_PATH="${CHART_PATH:-./openstudio-server}"
HELM_DEBUG="${HELM_DEBUG:-true}"

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

helm upgrade --install "${RELEASE_NAME}" "${CHART_PATH}" "${HELM_ARGS[@]}" --set "global.provider.name=${PROVIDER}"
