#!/bin/bash

# safe-delete-volumes.sh
# A script to safely delete OpenStack volumes after running diagnostics.
# Usage: ./safe-delete-volumes.sh
# Requirements: OpenStack CLI, jq

set -euo pipefail

# Source OpenStack credentials
source aurora-179d-openrc.sh

# Function to handle OpenStack authentication retries
retry_authentication() {
  local retries=3
  local count=0
  while [[ $count -lt $retries ]]; do
    if openstack token issue > /dev/null 2>&1; then
      echo "Authentication successful."
      return 0
    fi
    count=$((count + 1))
    echo "Authentication failed. Retrying ($count/$retries)..."
    sleep 5
  done
  echo "Authentication failed after $retries attempts. Exiting."
  exit 1
}

LOG_FILE="safe-delete-volumes.log"
exec > >(tee -i "$LOG_FILE") 2>&1

echo "Starting safe volume deletion at $(date)"

# Function to run diagnostics
run_diagnostics() {
  echo "Running diagnostics..."
  if [[ -z "${KUBERNETES_CLUSTER:-}" ]]; then
    echo "Kubernetes cluster is unavailable. Skipping diagnostics."
    return
  fi
  ./diagnose-volumes.sh
}

# Function to confirm deletion
confirm_deletion() {
  if [[ -z "${KUBERNETES_CLUSTER:-}" ]]; then
    echo "Kubernetes cluster is unavailable. Skipping Kubernetes checks."
    return
  fi
  read -p "Are you sure you want to delete the volumes? (yes/no): " confirmation
  if [[ "$confirmation" != "yes" ]]; then
    echo "Deletion aborted."
    exit 1
  fi
}

# Function to handle snapshots
handle_snapshots() {
  echo "Handling snapshots..."
  openstack volume snapshot list -f json | jq -r '.[] | "\(.id) \(.volume_id)"' | while read -r snapshot_id volume_id; do
    echo "Deleting snapshot $snapshot_id for volume $volume_id..."
    openstack volume snapshot delete "$snapshot_id"
  done
}

# Function to detach volumes
detach_volumes() {
  echo "Detaching volumes..."
  openstack volume list --all-projects -f json | jq -r '.[] | select(.status == "in-use") | "\(.id) \(.name)"' | while read -r volume_id volume_name; do
    echo "Detaching volume $volume_name ($volume_id)..."
    openstack server list --all-projects -f json | jq -r '.[] | "\(.ID)"' | while read -r server_id; do
      openstack server remove volume "$server_id" "$volume_id" || echo "Failed to detach volume $volume_id from server $server_id"
    done
  done
}

# Function to delete volumes
delete_volumes() {
  echo "Deleting volumes..."
  # Define the target volume IDs
  target_volumes=("eb090099-411a-47ed-9be1-9e29034e5ac7" "c3b1102f-4c9a-4883-ae86-01ef13919a4f" "c02ef405-bc03-4d6d-9511-c7e81bef3eb7" "b6d3b511-de5b-41bc-b00a-be2b77bdd1ff")

  # Parse and filter volumes
  echo "Fetching volume list..."
  volume_list=$(openstack volume list --all-projects -f json)
  echo "Volume list fetched: $volume_list"

  # Extract matching volumes
  echo "Parsing target volumes..."
  matching_volumes=$(echo "$volume_list" | jq -r --argjson targets "$(printf '%s\n' "${target_volumes[@]}" | jq -R . | jq -s .)" '
    .[] | select(.ID as $id | $targets | index($id)) | "\(.ID) \(.Name)"
  ')

  if [[ -z "$matching_volumes" ]]; then
      echo "No matching volumes found. Debugging information:"
      echo "Fetched volumes:"
      echo "$volume_list" | jq -r '.[] | "\(.id) \(.name)"'
      echo "Target volumes:"
      printf '%s\n' "${target_volumes[@]}"
      return
  fi

  echo "Volumes to delete:"
  echo "$matching_volumes"

  # Delete volumes
  echo "$matching_volumes" | while read -r volume_id volume_name; do
    echo "Deleting volume $volume_name ($volume_id)..."
    if ! openstack volume delete "$volume_id"; then
      echo "Failed to delete volume $volume_id"
    fi
  done
}

# Run all steps
retry_authentication
run_diagnostics
confirm_deletion
handle_snapshots
detach_volumes
delete_volumes

echo "Safe deletion completed at $(date)"