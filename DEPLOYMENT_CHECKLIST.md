# Deployment Checklist for Infrastructure Improvements

## Pre-Deployment Verification

### 1. Helm Chart Files Modified ✅

- [x] `openstudio-server/values.yaml`
  - Added Passenger tuning parameters
  - Added Nginx compression parameters
  - Added Nginx proxy buffering parameters
  - Added health check timeout parameters

- [x] `openstudio-server/templates/web/web-deploy.yaml`
  - Added init-verify-mnt-openstudio init container
  - Enhanced readiness probe to check /analyses.json
  - Added startup probe for gradual initialization
  - Enhanced liveness probe with write permission check
  - Added environment variables for Passenger and Nginx tuning

- [x] `openstudio-server/templates/web-background/web-background-deploy.yaml`
  - Added init-verify-mnt-openstudio init container
  - Enhanced liveness probe with write permission check

- [x] `openstudio-server/templates/rserve/rserve-deploy.yaml`
  - Added init-verify-mnt-openstudio init container
  - Enhanced liveness probe with write permission check

### 2. Documentation Files Created ✅

- [x] `INFRASTRUCTURE_IMPROVEMENTS.md` (Comprehensive guide)
- [x] `ANSWERS_TO_SPECIFIC_QUESTIONS.md` (Q&A format)
- [x] `DEPLOYMENT_CHECKLIST.md` (This file)

## Deployment Steps

### Step 1: Review Changes
```bash
# Review all modified files
git diff openstudio-server/values.yaml
git diff openstudio-server/templates/web/web-deploy.yaml
git diff openstudio-server/templates/web-background/web-background-deploy.yaml
git diff openstudio-server/templates/rserve/rserve-deploy.yaml
```

### Step 2: Validate Helm Chart
```bash
helm lint openstudio-server/
helm template openstudio-server/ > /tmp/rendered.yaml
# Review /tmp/rendered.yaml for any issues
```

### Step 3: Backup Current Configuration
```bash
# Get current deployment configuration
kubectl get deployment -n <namespace> -o yaml > current-deployment-backup.yaml
kubectl get values openstudio-server > current-values-backup.yaml
```

### Step 4: Deploy Changes (Dev/Staging First)
```bash
# Deploy to development/staging cluster first
helm upgrade openstudio-server openstudio-server/ \
  -f values-dev.yaml \
  -n default \
  --dry-run --debug

# If dry-run looks good, deploy for real
helm upgrade openstudio-server openstudio-server/ \
  -f values-dev.yaml \
  -n default
```

### Step 5: Monitor Rollout
```bash
# Watch pod deployment progress
kubectl rollout status deployment/web -n default --timeout=10m

# Watch pod events
kubectl get events -n default -w

# Check pod status
kubectl get pods -n default -l app=web

# Check init container logs
kubectl logs <web-pod> -c init-verify-mnt-openstudio -n default

# Check startup progress
kubectl logs <web-pod> -c web -n default | tail -50
```

## Post-Deployment Verification

### 1. Pod Startup Verification
```bash
# Verify pods started successfully
kubectl get pods -l app=web -n default

# Expected output: All pods should have STATUS: Running, READY: 1/1

# Check for init container success
kubectl describe pod <web-pod> -n default | grep -A 5 "Init Containers"
# Should show "State: Terminated" with "Reason: Completed"

# Verify no crash loops
kubectl get pods -l app=web -n default | grep -i "crash\|error"
# Should return nothing
```

### 2. Health Check Verification
```bash
# Verify startup probe is running
kubectl describe pod <web-pod> -n default | grep -A 5 "Startup"
# Should show "State: Running"

# Verify readiness probe status
kubectl describe pod <web-pod> -n default | grep -A 5 "Readiness"
# Should show "State: Running" and "Ready: True"

# Verify liveness probe status
kubectl describe pod <web-pod> -n default | grep -A 5 "Liveness"
# Should show "State: Running"
```

### 3. Response Compression Verification
```bash
# Download /analyses.json and check compression
curl -i http://<service-url>/analyses.json | head -20

# Look for:
# - "Content-Encoding: gzip" header
# - Content-Length: should be much smaller than actual JSON

# Get response size
curl -s http://<service-url>/analyses.json | wc -c
# Should be 5-10MB instead of 42MB

# Get uncompressed size (for comparison)
curl -s http://<service-url>/analyses.json | gunzip | wc -c
# Should be ~42MB
```

### 4. Passenger Pool Verification
```bash
# SSH into web pod
kubectl exec -it <web-pod> -n default -- /bin/bash

# Check Passenger status inside pod
passenger-status

# Look for:
# - Min instances: 2
# - Max instances: up to 32
# - Active processes should increase with load

# Check Passenger config
passenger --version
ps aux | grep passenger
```

### 5. Mount Point Verification
```bash
# Verify /mnt/openstudio is mounted
kubectl exec <web-pod> -n default -- mount | grep openstudio

# Verify write access
kubectl exec <web-pod> -n default -- touch /mnt/openstudio/test && echo "Success"
kubectl exec <web-pod> -n default -- rm /mnt/openstudio/test
```

### 6. Performance Metrics Collection
```bash
# Before and after comparison:
# 1. Response time for /analyses.json
time curl -s http://<service-url>/analyses.json > /dev/null

# 2. Compressed size
curl -s http://<service-url>/analyses.json | wc -c

# 3. Uncompressed size
curl -s http://<service-url>/analyses.json | gunzip | wc -c

# 4. Passenger instance count
kubectl exec <web-pod> -- passenger-status | grep "Total processes"

# 5. Pod readiness
kubectl get pod <web-pod> -n default -o jsonpath="{.status.conditions[?(@.type=='Ready')].status}"
```

## Rollback Procedure (If Needed)

### Quick Rollback
```bash
# Revert to previous Helm release
helm rollback openstudio-server -n default

# Monitor rollback
kubectl rollout status deployment/web -n default --timeout=5m
```

### Manual Rollback
```bash
# If helm rollback doesn't work:
kubectl set image deployment/web web=<previous-image> -n default

# Or restore from backup
kubectl apply -f current-deployment-backup.yaml -n default
```

## Troubleshooting

### Pod Won't Start / Init Container Failing

```bash
# Check init container logs
kubectl logs <web-pod> -c init-verify-mnt-openstudio -n default

# Likely causes:
# 1. /mnt/openstudio not mounted -> Check NFS provisioner
# 2. /mnt/openstudio not writable -> Check NFS permissions
# 3. PVC not bound -> Check PVC status with `kubectl get pvc`

# Debug NFS mount
kubectl exec <pod> -n default -- mount | grep openstudio
kubectl exec <pod> -n default -- ls -la /mnt/ | grep openstudio
kubectl exec <pod> -n default -- test -w /mnt/openstudio && echo "Writable"
```

### Readiness Probe Failing

```bash
# Check readiness probe status
kubectl describe pod <web-pod> -n default | grep -A 10 "Readiness"

# Check if /analyses.json endpoint is responding
kubectl exec <web-pod> -n default -- curl -v http://localhost/analyses.json

# Common causes:
# 1. Rails app still initializing -> Wait longer (max 5 min for startup probe)
# 2. Database not responding -> Check MongoDB pod
# 3. Redis not responding -> Check Redis pod
# 4. File I/O issues -> Check /mnt/openstudio access
```

### Response Not Compressed

```bash
# Check if gzip is configured
kubectl exec <web-pod> -n default -- \
  grep -r "gzip" /etc/nginx/

# Check if Nginx is actually compressing
curl -H "Accept-Encoding: gzip" -I http://<service-url>/analyses.json

# If not compressed, check:
# 1. Environment variables set correctly: kubectl describe pod
# 2. Nginx config file syntax: kubectl exec ... -- nginx -t
# 3. Content-Length >= 1024: Very small responses aren't compressed
```

## Success Criteria

After deployment, verify:

✅ **Startup**
- [ ] All pods start without init container errors
- [ ] No crash loops or restart loops
- [ ] Init container logs show "SUCCESS"

✅ **Health Checks**
- [ ] Readiness probes pass after 90-120 seconds
- [ ] Liveness probes pass continuously
- [ ] Startup probes complete within 5 minutes

✅ **Compression**
- [ ] Response includes "Content-Encoding: gzip" header
- [ ] Response size is 20-25% of original (5-10MB of 42MB)
- [ ] Uncompressed size matches original (42MB)

✅ **Performance**
- [ ] /analyses.json response time < 45 seconds
- [ ] No connection timeouts or 503 errors
- [ ] Passenger pool running 2-32 instances

✅ **Reliability**
- [ ] No pod restarts after initialization
- [ ] /mnt/openstudio mount verified in liveness probe
- [ ] No "permission denied" errors in logs

## Monitoring After Deployment

### Daily Checks
```bash
# Pod health
kubectl get pods -l app=web -n default

# Init container success rate (should be 100%)
kubectl get pods -l app=web -n default | grep Running | wc -l

# Check for recent restarts
kubectl get pods -l app=web -n default -o custom-columns=NAME:.metadata.name,RESTARTS:.status.containerStatuses[0].restartCount
```

### Weekly Checks
```bash
# Response time trends
kubectl logs -l app=web -n default --tail=1000 | grep analyses.json | tail -100

# Error rate
kubectl logs -l app=web -n default --tail=1000 | grep -i "error\|timeout\|failed" | wc -l

# Pod stability
kubectl get pods -l app=web -n default -o custom-columns=CREATED:.metadata.creationTimestamp
```

### Monthly Checks
```bash
# Long-term performance
kubectl top pod -l app=web -n default

# Compare compression ratios
# See "Response Compression Verification" section above

# Review liveness/readiness probe failures
kubectl describe deployment web -n default | grep -A 10 "Events:"
```

## Support & Escalation

If issues persist after deployment:

1. **Check Documentation**
   - Review `INFRASTRUCTURE_IMPROVEMENTS.md`
   - Review `ANSWERS_TO_SPECIFIC_QUESTIONS.md`
   - Check troubleshooting section above

2. **Collect Diagnostics**
   ```bash
   # Pod description
   kubectl describe pod <web-pod> -n default > diagnostics.txt
   
   # Pod logs (last 500 lines)
   kubectl logs <web-pod> -c web -n default --tail=500 >> diagnostics.txt
   
   # Init container logs
   kubectl logs <web-pod> -c init-verify-mnt-openstudio -n default >> diagnostics.txt
   
   # Pod events
   kubectl get events -n default | grep <web-pod> >> diagnostics.txt
   ```

3. **Review with Team**
   - Share diagnostics.txt with ops team
   - Reference which health check is failing
   - Provide git diff of changes made

## Sign-Off

After successful deployment and verification:

- [ ] Deployment completed without errors
- [ ] All success criteria met
- [ ] Monitoring in place
- [ ] Team notified of changes
- [ ] Documentation linked in deployment ticket

---

## Next Steps

After successful deployment:

1. **For OpenStudio BEM-to-Surrogate Gem Team**
   - Update gem to use `csv_connection_pool_size: 5` for parallel downloads
   - Reduce client-side read timeout to 60s (was 300s)
   - Verify automatic gzip decompression works

2. **For Operations Team**
   - Monitor `/analyses.json` response times daily
   - Track Passenger pool utilization
   - Watch for any mount point issues

3. **For Future Improvements**
   - Plan ETags support for conditional requests
   - Design pagination API for /analyses.json
   - Evaluate Prometheus metrics integration
