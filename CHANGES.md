# Changes Made to Fix OpenStudio Server File Upload Issue

## Problem
The `bundle exec rake execute_sequential` command was failing with a 500 Internal Server Error when attempting to upload analysis ZIP files to the OpenStudio server. The error occurred during the file upload phase after the analysis record was successfully created.

## Root Cause
The OpenStudio Server Kubernetes deployment had two configuration mismatches compared to the working docker-compose setup:

1. **Missing `OS_SERVER_PROJECT_PATH` environment variable**: The server didn't know where to store uploaded files. The default configuration (`:rails_root/../worker-nodes` → `/opt/worker-nodes`) pointed to container-local storage, not the shared NFS volume.

2. **Worker pod using emptyDir instead of NFS PVC**: The worker pod mounted an emptyDir at `/mnt/openstudio` while the web pod mounted the shared NFS PVC at the same path. This meant:
   - Web pod uploaded files to NFS PVC at `/mnt/openstudio/server/assets/analyses/...`
   - Worker pod tried to read from its own emptyDir at `/mnt/openstudio/server/assets/analyses/...` (empty!)
   - Files were never accessible to workers for processing

**Why it worked in docker-compose:**
- `RAILS_ENV=docker` → uses config.yml's "docker" environment with `os_server_project_path: '/mnt/openstudio'`
- ALL containers (web, web-background, rserve, **worker**) mount the same shared volume at `/mnt/openstudio`

## Solution
Fixed both issues in the Helm chart:

### Files Modified:
1. `openstudio-server/templates/web/web-deploy.yaml` - Added `OS_SERVER_PROJECT_PATH=/mnt/openstudio` to web container env
2. `openstudio-server/templates/worker/worker-deploy.yaml` - Added `OS_SERVER_PROJECT_PATH=/mnt/openstudio` to worker container env AND changed volume from emptyDir to NFS PVC
3. `openstudio-server/templates/web-background/web-background-deploy.yaml` - Added `OS_SERVER_PROJECT_PATH=/mnt/openstudio` to web-background container env

### Key Changes:

**Web & Web-Background:** Added environment variable
```yaml
env:
  - name: OS_SERVER_PROJECT_PATH
    value: "/mnt/openstudio"
```

**Worker:** Added environment variable AND changed to NFS PVC
```yaml
# Before (broken):
volumeMounts:
  - name: osdata-worker
    mountPath: "/mnt/openstudio"
volumes:
  - name: osdata-worker
    emptyDir: {}

# After (fixed):
volumeMounts:
  - name: nfs
    mountPath: "/mnt/openstudio"
volumes:
  - name: nfs
    persistentVolumeClaim:
      claimName: nfs-pvc
```

## How to Apply
```bash
helm upgrade openstudio-server ./openstudio-server -f openstack/values-openstack.yaml
```

## Verification
After pods restart with the new configuration:
1. Web pod uploads files to `/mnt/openstudio/server/assets/analyses/...` (NFS PVC)
2. Worker pod reads files from `/mnt/openstudio/server/assets/analyses/...` (SAME NFS PVC)
3. File upload succeeds, analysis processing works

## Alternative Solutions Considered

### From the Gem Side (openstudio-bem-to-surrogate-gem)
The gem cannot fix this - it only generates ZIP files and sends them via HTTP. The server must be configured correctly to receive and store them.

### Other Server-Side Options
1. **Set `RAILS_ENV=docker` in Kubernetes** - Would use docker config with `/mnt/openstudio` path, but still requires worker to mount NFS PVC
2. **Make path configurable in Helm values** - More flexible but requires more changes
3. **Use different storage backend** - Not necessary for this fix

The current fix is minimal, targeted, and matches the proven docker-compose architecture.