#!/usr/bin/env bash
set -euo pipefail

# Validate chart rendering across provider matrix, OpenStack overlays, and secret modes.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHART_DIR="${ROOT_DIR}/openstudio-server"

helm lint "${CHART_DIR}" --set global.provider.name=aws >/dev/null
helm template openstudio-server "${CHART_DIR}" --set global.provider.name=aws >/dev/null
helm template openstudio-server "${CHART_DIR}" --set global.provider.name=google >/dev/null
helm template openstudio-server "${CHART_DIR}" --set global.provider.name=azure >/dev/null
helm template openstudio-server "${CHART_DIR}" --set global.provider.name=openstack >/dev/null
helm template openstudio-server "${CHART_DIR}" -f "${ROOT_DIR}/openstack/values-openstack.yaml" >/dev/null
helm template openstudio-server "${CHART_DIR}" -f "${ROOT_DIR}/openstack/values-openstack-nfs.yaml" >/dev/null
helm template openstudio-server "${CHART_DIR}" -f "${ROOT_DIR}/openstack/values-openstack-nfs-small.yaml" >/dev/null
helm template openstudio-server "${CHART_DIR}" \
  --set global.provider.name=aws \
  --set secrets.existingSecret= \
  --set secrets.create=true \
  --set db.username=chart-user \
  --set db.password=chart-pass \
  --set redis.password=chart-pass \
  --set web.secret_key_value=chart-secret >/dev/null

if helm template openstudio-server "${CHART_DIR}" >/dev/null 2>&1; then
  echo "Expected failure when global.provider.name is unset"
  exit 1
fi

if helm template openstudio-server "${CHART_DIR}" \
  --set global.provider.name=aws \
  --set secrets.create=true >/dev/null 2>&1; then
  echo "Expected failure when secrets.create=true and required credential values are missing"
  exit 1
fi

if helm template openstudio-server "${CHART_DIR}" \
  --set global.provider.name=aws \
  --set secrets.existingSecret=openstudio-app-secrets \
  --set secrets.create=true >/dev/null 2>&1; then
  echo "Expected failure when secrets.existingSecret and secrets.create=true are both set"
  exit 1
fi

helm template openstudio-server "${CHART_DIR}" \
  --set global.provider.name=aws \
  --set db.name=custom-db \
  --set redis.name=custom-redis \
  --set nfs_pvc.name=custom-nfs-pvc \
  --set load_balancer.name=custom-lb \
  --set load_balancer.ports.http_port=8080 \
  --set load_balancer.ports.https_port=8443 >/dev/null

echo "Helm lint/render matrix completed."
