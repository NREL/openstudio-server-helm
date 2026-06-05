#!/usr/bin/env bash
set -euo pipefail

# Validate chart rendering across default, OpenStack overlays, and compatibility overrides.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHART_DIR="${ROOT_DIR}/openstudio-server"

helm lint "${CHART_DIR}" >/dev/null
helm template openstudio-server "${CHART_DIR}" >/dev/null
helm template openstudio-server "${CHART_DIR}" -f "${ROOT_DIR}/openstack/values-openstack.yaml" >/dev/null
helm template openstudio-server "${CHART_DIR}" -f "${ROOT_DIR}/openstack/values-openstack-nfs.yaml" >/dev/null
helm template openstudio-server "${CHART_DIR}" -f "${ROOT_DIR}/openstack/values-openstack-nfs-small.yaml" >/dev/null
helm template openstudio-server "${CHART_DIR}" \
  --set db.name=custom-db \
  --set redis.name=custom-redis \
  --set nfs_pvc.name=custom-nfs-pvc \
  --set load_balancer.name=custom-lb \
  --set load_balancer.ports.http_port=8080 \
  --set load_balancer.ports.https_port=8443 >/dev/null

echo "Helm lint/render matrix completed."
