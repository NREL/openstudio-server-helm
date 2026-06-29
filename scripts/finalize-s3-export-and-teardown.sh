#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="openstudio-server"
CRONJOB_NAME="openstudio-server-s3-incremental-sync"
TIMEOUT_SECONDS="600s"
TEARDOWN_CMD=""

usage() {
  cat <<'USAGE'
Usage:
  finalize-s3-export-and-teardown.sh [options]

Options:
  -n, --namespace <name>      Kubernetes namespace (default: openstudio-server)
  -c, --cronjob <name>        CronJob name (default: openstudio-server-s3-incremental-sync)
  -t, --timeout <duration>    Wait timeout for each sync job (default: 600s)
  --teardown-cmd <command>    Command to run only after successful final sync
  -h, --help                  Show this help text
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--namespace)
      NAMESPACE="$2"
      shift 2
      ;;
    -c|--cronjob)
      CRONJOB_NAME="$2"
      shift 2
      ;;
    -t|--timeout)
      TIMEOUT_SECONDS="$2"
      shift 2
      ;;
    --teardown-cmd)
      TEARDOWN_CMD="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

run_final_sync() {
  local attempt="$1"
  local suffix job_name
  suffix="$(date -u +%Y%m%d%H%M%S)-a${attempt}"
  job_name="final-completion-sync-${suffix}"

  echo "Creating final sync job ${job_name} from cronjob/${CRONJOB_NAME} in namespace ${NAMESPACE}"
  kubectl -n "${NAMESPACE}" create job --from=cronjob/"${CRONJOB_NAME}" "${job_name}" >/dev/null

  if kubectl -n "${NAMESPACE}" wait --for=condition=complete "job/${job_name}" --timeout="${TIMEOUT_SECONDS}" >/dev/null; then
    echo "Final sync job ${job_name} completed successfully."
    return 0
  fi

  echo "Final sync job ${job_name} failed or timed out. Logs:"
  kubectl -n "${NAMESPACE}" logs "job/${job_name}" --all-containers=true || true
  return 1
}

if ! run_final_sync 1; then
  echo "Retrying final sync once..."
  if ! run_final_sync 2; then
    echo "Final sync failed after retry. Cluster teardown is blocked."
    exit 1
  fi
fi

if [[ -n "${TEARDOWN_CMD}" ]]; then
  echo "Running teardown command: ${TEARDOWN_CMD}"
  bash -lc "${TEARDOWN_CMD}"
else
  echo "Final sync complete. Ready for node group teardown."
  echo ""
  echo "To scale down node groups (keeps cluster control plane):"
  echo "  eksctl scale nodegroup --cluster <cluster-name> --name <nodegroup-name> --nodes 0 --region <region>"
  echo ""
  echo "Example: scale all worker nodes to 0"
  echo "  eksctl scale nodegroup --cluster openstudio-server-03 --name worker-node-group-spot-2a --nodes 0 --region us-west-2"
fi
