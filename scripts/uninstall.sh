#!/bin/bash
# Uninstall the openstudio-server release.
#
# The chart's pre-delete hook (templates/hooks/pre-delete-hook.yaml) handles
# the cleanup ordering: it deletes the app Deployments/StatefulSets (web,
# web-background, rserve, worker, db, redis) while deliberately KEEPING the
# NFS server provisioner up until the NFS clients have unmounted, then Helm
# deletes the remaining release resources.
#
# Do NOT manually `kubectl delete deployment web web-background rserve` before
# uninstalling -- that races the hook and can leave the release in a broken
# half-deleted state. The hook now runs without `--wait` so Failed/Error pods
# (e.g. OOM-killed web) do not block it, and the hook Job itself will be
# removed by Helm once it succeeds.
#
# Usage:
#   scripts/uninstall.sh [--namespace <ns>] [--timeout 10m]

set -euo pipefail

NAMESPACE="${NAMESPACE:-openstudio-server}"
RELEASE="${RELEASE:-openstudio-server}"
TIMEOUT="${TIMEOUT:-10m}"

echo "Uninstalling Helm release '${RELEASE}' from namespace '${NAMESPACE}' (timeout ${TIMEOUT})..."
helm uninstall "${RELEASE}" --namespace "${NAMESPACE}" --wait --timeout "${TIMEOUT}" --debug

echo "Verifying remaining resources in namespace '${NAMESPACE}':"
kubectl get all,pvc,cm,secret,sa,role,rolebinding,job -n "${NAMESPACE}" 2>/dev/null || echo "  (namespace '${NAMESPACE}' is empty or no longer exists)"
