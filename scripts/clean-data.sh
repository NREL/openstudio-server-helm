#!/usr/bin/env bash
# Clean OpenStudio Server: Delete projects, analyses, and associated data to start fresh
# This script deletes database data, clears Redis, and optionally wipes persistent volumes
# WARNING: This is destructive and cannot be undone!

set -euo pipefail

NAMESPACE="${NAMESPACE:-openstudio-server}"
DRY_RUN=false
DELETE_PVS=false
FORCE=false
REDIS_PASSWORD="${REDIS_PASSWORD:-openstudio}"

usage() {
  cat <<'USAGE'
Usage:
  clean-data.sh [options]

Description:
  Deletes projects, analyses, and associated data from the OpenStudio Server cluster.
  This includes:
    - PostgreSQL database data (projects, analyses, results)
    - Redis cache
    - NFS shared filesystem data (optionally)
    - Persistent volumes (optionally)

Options:
  -n, --namespace <name>      Kubernetes namespace (default: openstudio-server)
  --dry-run                   Show what would be deleted without making changes
  --delete-pvs                Also delete persistent volume claims (destructive!)
  -f, --force                 Skip confirmation prompts
  -h, --help                  Show this help text

Examples:
  # Preview what would be deleted (safe)
  ./clean-data.sh --dry-run

  # Delete database and Redis data, keep volumes
  ./clean-data.sh

  # Delete everything including volumes
  ./clean-data.sh --delete-pvs

  # Skip all prompts
  ./clean-data.sh -f

USAGE
}

log_info() {
  echo "[INFO] $*"
}

log_warn() {
  echo "[WARN] $*" >&2
}

log_error() {
  echo "[ERROR] $*" >&2
}

confirm() {
  local prompt="$1"
  
  if [[ "${FORCE}" == "true" ]]; then
    return 0
  fi
  
  local response
  read -p "${prompt} (yes/no): " response
  [[ "${response}" == "yes" ]]
}

check_kubectl() {
  if ! command -v kubectl &> /dev/null; then
    log_error "kubectl not found. Please install kubectl."
    exit 1
  fi
  
  if ! kubectl cluster-info &> /dev/null; then
    log_error "Not connected to a Kubernetes cluster."
    exit 1
  fi
}

check_namespace() {
  if ! kubectl get namespace "${NAMESPACE}" &> /dev/null; then
    log_error "Namespace '${NAMESPACE}' does not exist."
    exit 1
  fi
}

get_pod_by_label() {
  local label="$1"
  kubectl -n "${NAMESPACE}" get pods \
    -l "${label}" \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | awk '{print $1}'
}

get_pod_by_any_label() {
  local pod=""
  local label
  for label in "$@"; do
    pod="$(get_pod_by_label "${label}")"
    if [[ -n "${pod}" ]]; then
      echo "${pod}"
      return 0
    fi
  done
  echo ""
}

exec_in_pod() {
  local pod="$1"
  local cmd="$2"
  
  if [[ -z "${pod}" ]]; then
    log_warn "Pod not found for command: ${cmd}"
    return 1
  fi
  
  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "[DRY RUN] Would execute in pod ${pod}: ${cmd}"
    return 0
  fi
  
  kubectl -n "${NAMESPACE}" exec "${pod}" -- bash -c "${cmd}"
}

clean_database() {
  log_info "Cleaning database..."
  
  local db_pod
  db_pod=$(get_pod_by_any_label \
    "app.kubernetes.io/name=openstudio-server,app.kubernetes.io/component=db" \
    "app=db")
  
  if [[ -z "${db_pod}" ]]; then
    log_warn "Database pod not found. Skipping database cleanup."
    return
  fi
  
  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "[DRY RUN] Would drop all non-system MongoDB databases"
    return
  fi
  
  log_info "Dropping non-system MongoDB databases..."
  exec_in_pod "${db_pod}" "mongosh \
    -u \"\$MONGO_INITDB_ROOT_USERNAME\" \
    -p \"\$MONGO_INITDB_ROOT_PASSWORD\" \
    --authenticationDatabase admin \
    --quiet \
    --eval '
      const protectedDbs = new Set([\"admin\", \"config\", \"local\"]);
      const dbs = db.adminCommand({ listDatabases: 1 }).databases.map(d => d.name);
      dbs.filter(name => !protectedDbs.has(name)).forEach(dbName => {
        const result = db.getSiblingDB(dbName).dropDatabase();
        print(\"Dropped \" + dbName + \": \" + (result.ok === 1 ? \"ok\" : tojson(result)));
      });
    '"
  
  log_info "Database cleanup complete."
}

clean_redis() {
  log_info "Cleaning Redis cache..."
  
  local redis_pod
  redis_pod=$(get_pod_by_any_label \
    "app.kubernetes.io/name=openstudio-server,app.kubernetes.io/component=redis" \
    "app=redis")
  
  if [[ -z "${redis_pod}" ]]; then
    log_warn "Redis pod not found. Skipping Redis cleanup."
    return
  fi
  
  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "[DRY RUN] Would flush all Redis data"
    return
  fi
  
  if exec_in_pod "${redis_pod}" "redis-cli -a \"${REDIS_PASSWORD}\" FLUSHALL"; then
    log_info "Redis cache cleared."
  else
    log_error "Failed to flush Redis cache."
    return 1
  fi
}

clean_nfs_data() {
  log_info "Cleaning NFS shared filesystem..."
  
  local nfs_pod
  nfs_pod=$(get_pod_by_any_label \
    "app.kubernetes.io/name=openstudio-server,app.kubernetes.io/component=web" \
    "app=web")
  
  if [[ -z "${nfs_pod}" ]]; then
    log_warn "Web pod not found. Skipping NFS cleanup."
    return
  fi
  
  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "[DRY RUN] Would delete NFS data directories"
    return
  fi
  
  # Remove analysis results and project files
  exec_in_pod "${nfs_pod}" "rm -rf /mnt/openstudio/projects /mnt/openstudio/analyses 2>/dev/null || true"
  
  # Ensure directories exist for fresh start
  exec_in_pod "${nfs_pod}" "mkdir -p /mnt/openstudio/projects /mnt/openstudio/analyses"
  
  log_info "NFS shared filesystem cleaned."
}

list_pvcs() {
  log_info "Persistent Volume Claims in namespace '${NAMESPACE}':"
  kubectl -n "${NAMESPACE}" get pvc -o wide
}

delete_pvcs() {
  log_info "Deleting Persistent Volume Claims..."
  
  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "[DRY RUN] Would delete the following PVCs:"
    list_pvcs
    return
  fi
  
  local pvcs
  pvcs=$(kubectl -n "${NAMESPACE}" get pvc -o jsonpath='{.items[*].metadata.name}')
  
  if [[ -z "${pvcs}" ]]; then
    log_info "No PVCs found."
    return
  fi
  
  for pvc in ${pvcs}; do
    log_info "Deleting PVC: ${pvc}"
    kubectl -n "${NAMESPACE}" delete pvc "${pvc}" --ignore-not-found=true
  done
  
  # Wait for PVs to be deleted
  log_info "Waiting for persistent volumes to be released..."
  sleep 5
  
  log_info "Persistent volumes deleted."
}

main() {
  # Parse arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--namespace)
        NAMESPACE="$2"
        shift 2
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      --delete-pvs)
        DELETE_PVS=true
        shift
        ;;
      -f|--force)
        FORCE=true
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        log_error "Unknown argument: $1"
        usage
        exit 1
        ;;
    esac
  done
  
  # Validate environment
  check_kubectl
  check_namespace
  
  log_info "OpenStudio Server Data Cleanup Script"
  log_info "========================================"
  log_info "Namespace: ${NAMESPACE}"
  
  if [[ "${DRY_RUN}" == "true" ]]; then
    log_warn "DRY RUN MODE - No changes will be made"
  fi
  
  echo ""
  
  # Show what will be deleted
  log_info "This script will delete:"
  echo "  - All projects and analyses from MongoDB"
  echo "  - All data points and results"
  echo "  - Redis cache"
  echo "  - Analysis and project files from NFS"
  
  if [[ "${DELETE_PVS}" == "true" ]]; then
    echo "  - All Persistent Volume Claims (DESTRUCTIVE!)"
  fi
  
  echo ""
  
  if ! confirm "⚠️  Are you absolutely sure you want to proceed?"; then
    log_info "Cleanup cancelled."
    exit 0
  fi
  
  if [[ "${DELETE_PVS}" == "true" ]] && ! confirm "⚠️  Delete PVCs? This will destroy persistent volumes."; then
    DELETE_PVS=false
    log_info "PVC deletion skipped."
  fi
  
  echo ""
  
  # Perform cleanup
  clean_database
  clean_redis
  clean_nfs_data
  
  if [[ "${DELETE_PVS}" == "true" ]]; then
    delete_pvcs
  else
    log_info "Persistent volumes retained. Run with --delete-pvs to remove them."
  fi
  
  echo ""
  
  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "Dry run complete. No changes were made."
  else
    log_info "✓ Cleanup complete! Database and cache have been cleared."
    log_info "The system is ready to accept new projects and analyses."
  fi
}

main "$@"
