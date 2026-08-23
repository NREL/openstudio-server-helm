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
# On this cluster the apiserver's watch streams are known to drop mid-uninstall
# ("unable to decode an event from the watch stream ... INTERNAL_ERROR"). Helm's
# waits (both for cluster-scoped resources and for hook Job status) are relay/watch
# based and don't recover from a dropped watch -- they just burn the remaining
# --timeout and exit non-zero, even though the underlying resource/Job already
# finished. See docs/helm-uninstall-nfs-cleanup-hook-incident.md (Bug B) for the
# first occurrence (PriorityClasses/StorageClass) and its recurrence against the
# hook Job's own status. Retrying the uninstall almost always succeeds immediately
# because the release is already in "uninstalling" state and the hook has nothing
# left to do.
#
# Usage:
#   scripts/uninstall.sh [--namespace <ns>] [--timeout 10m]
#
# Env vars:
#   NAMESPACE, RELEASE, TIMEOUT, RETRIES (default 3), RETRY_DELAY_SECONDS (default 10)

set -euo pipefail

NAMESPACE="${NAMESPACE:-openstudio-server}"
RELEASE="${RELEASE:-openstudio-server}"
TIMEOUT="${TIMEOUT:-10m}"
RETRIES="${RETRIES:-3}"
RETRY_DELAY_SECONDS="${RETRY_DELAY_SECONDS:-10}"

# Errors that indicate a watch-stream hiccup rather than a real cleanup failure --
# safe to retry. Do NOT add generic Job-failure messages here; a genuinely Failed
# hook Job needs the force-clean runbook, not a blind retry.
RETRYABLE_PATTERN='INTERNAL_ERROR|context deadline exceeded|not ready\. status: InProgress'

attempt=1
while true; do
  echo "Uninstalling Helm release '${RELEASE}' from namespace '${NAMESPACE}' (timeout ${TIMEOUT}, attempt ${attempt}/${RETRIES})..."
  if output=$(helm uninstall "${RELEASE}" --namespace "${NAMESPACE}" --wait --timeout "${TIMEOUT}" --debug 2>&1); then
    echo "${output}"
    break
  fi
  echo "${output}"

  if echo "${output}" | grep -Eq "^Error: release: not found$"; then
    echo "Release already gone; nothing to do."
    break
  fi

  if [ "${attempt}" -ge "${RETRIES}" ] || ! echo "${output}" | grep -Eq "${RETRYABLE_PATTERN}"; then
    echo "Uninstall failed and is not a known-retryable watch-stream error (or retries exhausted)." >&2
    echo "See docs/helm-uninstall-force-clean-runbook.md for manual cleanup steps." >&2
    exit 1
  fi

  attempt=$((attempt + 1))
  echo "Detected a retryable watch-stream error; retrying in ${RETRY_DELAY_SECONDS}s..."
  sleep "${RETRY_DELAY_SECONDS}"
done

echo "Verifying remaining resources in namespace '${NAMESPACE}':"
kubectl get all,pvc,cm,secret,sa,role,rolebinding,job -n "${NAMESPACE}" 2>/dev/null || echo "  (namespace '${NAMESPACE}' is empty or no longer exists)"
