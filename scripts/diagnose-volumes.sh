#!/bin/bash

# Diagnostic Script for Investigating OpenStack Volume Recreation Issues

# Load OpenStack credentials
if [ -f aurora-179d-openrc.sh ]; then
  source aurora-179d-openrc.sh
else
  echo "OpenStack credentials file (aurora-179d-openrc.sh) not found."
  exit 1
fi

# Log file for diagnostics
LOG_FILE="diagnose-volumes.log"
echo "Starting diagnostic script at $(date)" > $LOG_FILE

# Function to log and display messages
log() {
  echo "$1" | tee -a $LOG_FILE
}

# 1. Check for Cinder Backup Jobs
log "Checking for Cinder backup jobs..."
openstack backup list --long >> $LOG_FILE 2>&1

# 2. Investigate Volume Snapshots
log "Checking for volume snapshots..."
openstack snapshot list --long >> $LOG_FILE 2>&1

# 3. Analyze OpenStack Orchestration Tools
log "Checking for Heat stacks..."
openstack stack list --long >> $LOG_FILE 2>&1

log "Checking for Terraform state files..."
if [ -d "/var/lib/terraform" ]; then
  find /var/lib/terraform -name "*.tfstate" >> $LOG_FILE 2>&1
else
  log "Terraform state directory not found."
fi

# 4. Look for Scheduled Jobs
log "Checking for cron jobs..."
crontab -l >> $LOG_FILE 2>&1

# 5. Examine Volume Type Configurations
log "Checking volume type configurations..."
openstack volume type list --long >> $LOG_FILE 2>&1

# 6. Monitor API Activity
log "Checking recent API activity..."
openstack audit event list --long >> $LOG_FILE 2>&1

# 7. Review Backup Policies
log "Checking backup policies..."
openstack volume backup policy list --long >> $LOG_FILE 2>&1

# 8. Inspect Storage Policies
log "Checking storage policies..."
openstack storage policy list --long >> $LOG_FILE 2>&1

# 9. Analyze Volume Metadata
log "Analyzing volume metadata..."
openstack volume list --long >> $LOG_FILE 2>&1

# 10. Look for Patterns in Volume Creation Timing
log "Analyzing volume creation timestamps..."
openstack volume list --format json | jq '.[] | {ID: .ID, Created: .Created}' >> $LOG_FILE 2>&1

# Completion message
log "Diagnostics completed. Check $LOG_FILE for details."
