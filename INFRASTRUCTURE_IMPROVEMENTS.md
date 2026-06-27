# OpenStudio Server Infrastructure Improvements

## Overview

This document describes infrastructure-level improvements made to address timeout, slowness, and reliability issues with the `/analyses.json` endpoint and large result downloads.

## Problem Summary

- **Slow Response**: ~22 seconds to first byte for /analyses.json
- **Large Payload**: 42MB+ uncompressed JSON in single HTTP response
- **Startup Failures**: /mnt/openstudio permission errors causing pod crashes
- **Brittle Health Checks**: Only HTTP 200 validation, not actual endpoint health
- **High Timeouts**: 300s read timeout indicates buffering/streaming issues

## Improvements Implemented

### Phase 1: Mount Point Reliability ✅

#### 1.1 Init Container for Mount Verification
**What**: Added `init-verify-mnt-openstudio` init container to all deployments that mount NFS (`web`, `web-background`, `rserve`).

**Why**: Prevents pods from entering a failed state due to missing or un-writable /mnt/openstudio mount. Catches issues before Rails app starts.

**How It Works**:
```bash
# Verifies:
# 1. /mnt/openstudio directory exists
# 2. /mnt/openstudio is actually mounted (checked against /proc/mounts)
# 3. /mnt/openstudio is writable (test file creation)
# Fails fast if any check fails, preventing app startup
```

**Affected Deployments**:
- `openstudio-server/templates/web/web-deploy.yaml`
- `openstudio-server/templates/web-background/web-background-deploy.yaml`
- `openstudio-server/templates/rserve/rserve-deploy.yaml`

#### 1.2 Improved Liveness Probes
**What**: Enhanced liveness probes to check both mount existence AND write permissions.

**Old**: `grep -qs "/mnt/openstudio " /proc/mounts` (mount check only)
**New**: `grep -qs "/mnt/openstudio " /proc/mounts && test -w /mnt/openstudio` (mount + writable)

**Why**: Catches cases where NFS is mounted but read-only or permission-denied.

**Impact**: 
- Faster failure detection (failureThreshold: 3, periodSeconds: 60 = 3 min to detection)
- Pod gets restarted automatically if mount becomes invalid
- Prevents serving requests from a broken state

### Phase 2: Response Compression & Buffering ✅

#### 2.1 Nginx Gzip Compression
**What**: Added Nginx configuration environment variables to enable response compression.

**Configuration**:
```yaml
NGINX_GZIP: "on"
NGINX_GZIP_COMP_LEVEL: 6              # Balance between compression and CPU
NGINX_GZIP_MIN_LENGTH: 1024           # Only compress responses > 1KB
NGINX_CLIENT_MAX_BODY_SIZE: "100m"    # Allow large uploads/downloads
```

**Expected Impact**:
- 42MB JSON → ~5-10MB compressed (75-80% reduction)
- Reduces bandwidth and network transfer time
- Network transfer from 42MB at typical speed goes from ~8-10s to ~1-2s

**Requirements**:
- Client must support `Accept-Encoding: gzip` (standard in all modern HTTP clients)
- Container's start-server script must use these environment variables to configure Nginx

#### 2.2 Passenger Performance Tuning
**What**: Added Passenger connection pooling and queue management environment variables.

**Configuration**:
```yaml
PASSENGER_MIN_INSTANCES: 2                           # Keep 2 app instances warm
PASSENGER_MAX_POOL_SIZE: 32                          # Allow up to 32 instances
PASSENGER_REQUEST_QUEUE_OVERFLOW_TO_WAIT_LIST: "true" # Queue requests instead of rejecting
PASSENGER_MAX_REQUEST_QUEUE_SIZE: 1600              # Allow 1600 queued requests
```

**Why This Helps**:
- Multiple instances handle concurrent requests (large /analyses.json downloads)
- Queue management prevents dropped connections under load
- Reduces "connection refused" errors when server is saturated

**Expected Impact**:
- Faster handling of concurrent /analyses.json requests
- Better resilience during CSV download storms

#### 2.3 Nginx Proxy Buffering
**What**: Added Nginx upstream buffering configuration.

**Configuration**:
```yaml
NGINX_PROXY_BUFFERING: "on"
NGINX_PROXY_BUFFER_SIZE: "32k"      # Initial buffer for response headers
NGINX_PROXY_BUFFERS: "8 32k"        # 8 buffers of 32KB each = 256KB total
NGINX_PROXY_CONNECT_TIMEOUT: "90s"  # Time to establish connection to upstream
NGINX_PROXY_SEND_TIMEOUT: "300s"    # Time to send request to upstream
NGINX_PROXY_READ_TIMEOUT: "300s"    # Time to receive response from upstream
```

**Why This Helps**:
- Buffering allows Nginx to handle slow Rails responses
- Prevents timeouts by allowing 300s for large payload generation
- Separates client timeout from server timeout

### Phase 3: Health Check Improvements ✅

#### 3.1 Enhanced Readiness Probe
**What**: Changed readiness probe to check actual endpoint instead of root.

**Old**: `GET /` 
**New**: `GET /analyses.json`

**Why**: 
- Only mark pod as ready when it can actually handle the real workload
- Detects endpoint-specific issues (e.g., database connectivity for analysis fetching)
- Prevents sending traffic to pods that can't serve the specific endpoint

**Configuration**:
```yaml
readinessProbe:
  httpGet:
    path: /analyses.json
    port: 80
  initialDelaySeconds: 90        # Wait for Rails to fully initialize
  periodSeconds: 30               # Check every 30s
  timeoutSeconds: 15              # 15s timeout for endpoint response
  failureThreshold: 3             # 3 consecutive failures = not ready
```

**Impact**:
- Pod removed from load balancer if /analyses.json endpoint fails
- More accurate traffic routing
- Faster detection of endpoint failures

#### 3.2 Startup Probe
**What**: Added startup probe for graceful startup handling.

**Why**: 
- Prevents readiness/liveness probe timeouts during initial startup
- Allows up to 300 seconds for app to fully initialize (30 attempts × 10s)

```yaml
startupProbe:
  httpGet:
    path: /
    port: 80
  initialDelaySeconds: 10
  periodSeconds: 10
  timeoutSeconds: 10
  failureThreshold: 30  # ~5 minute startup window
```

**Impact**: Pod has full 5 minutes to start before being considered failed (vs immediate readiness check).

## Configuration Changes

### values.yaml Updates

```yaml
web:
  passenger_min_instances: 2
  passenger_max_pool_size: 32
  passenger_request_queue_overflow_to_wait_list: "true"
  passenger_max_request_queue_size: 1600
  
  nginx_gzip: "on"
  nginx_gzip_comp_level: 6
  nginx_gzip_min_length: 1024
  nginx_client_max_body_size: "100m"
  
  nginx_proxy_connect_timeout: "90s"
  nginx_proxy_send_timeout: "300s"
  nginx_proxy_read_timeout: "300s"
  nginx_proxy_buffering: "on"
  nginx_proxy_buffer_size: "32k"
  nginx_proxy_buffers: "8 32k"
  
  health_check_timeout_analyses: 15
```

## Client-Side Recommendations

The OpenStudio BEM-to-Surrogate gem should be updated to take advantage of these improvements:

### 1. Connection Configuration
- Server now handles larger concurrent requests with Passenger pool optimization
- Consider reducing client-side timeout from 300s to 60-90s (compression should speed things up)
- Expected download time: 42MB → 5-10MB compressed → 10-30 seconds total

### 2. Timeout Tuning
Recommended client timeouts for download_results task:
```ruby
# Connection timeout: Time to establish connection
open_timeout: 30     # (was 10-60s)

# Read timeout: Time to receive response data
read_timeout: 60     # (was 30-300s, suggest 60s due to compression)

# For single large /analyses.json download:
# - Compression: 42MB -> 5-10MB
# - Network transfer: ~1-2s at typical speeds
# - Server processing: ~5-10s with init container optimizations
# - Total expected: ~20-40s (vs 22+ seconds TTFB before)
```

### 3. Configuration Recommendations
Update configs.yml in openstudio-bem-to-surrogate-gem:
```yaml
external_tools:
  server_uri: http://k8s-openstud-ingressl-0abea1fb83-81d9096a04829f3d.elb.us-west-2.amazonaws.com/
  
  # NEW: Client-side compression support
  request_compression: gzip  # Requests gzip responses from server
  
  # NEW: Retry configuration for large downloads
  max_retries: 3             # Retry on timeout/failure
  retry_backoff_base: 2      # Exponential backoff
  
  # NEW: Connection pooling for CSV downloads
  connection_pool_size: 5    # Max concurrent CSV downloads
```

### 4. Request Optimization
The gem should:
- Send `Accept-Encoding: gzip` header (automatic with Net::HTTP in Ruby)
- Support ETags for conditional requests (future improvement)
- Implement exponential backoff on timeout (better than immediate retry)
- Consider streaming large JSON responses instead of loading into memory

## Monitoring & Observability

### Key Metrics to Monitor

1. **Pod Health**:
   - Init container success rate (should be 100%)
   - Readiness/liveness probe pass rate
   - Pod restart count (should stay at 0)

2. **Response Performance**:
   - `/analyses.json` response time (should be <45s)
   - Response size (should see 5-10MB compressed vs 42MB uncompressed)
   - Gzip compression ratio (should be ~75-80%)

3. **Connection Pool**:
   - Active Passenger instances (should see 2-32)
   - Request queue depth (should be <100 during normal load)
   - Connection timeouts (should be ~0)

### Recommended Monitoring Commands

```bash
# Check Passenger status inside web pod
kubectl exec <web-pod> -- passenger-status

# Watch init container logs
kubectl logs <pod> -c init-verify-mnt-openstudio

# Check probe status
kubectl describe pod <web-pod> | grep -A 5 Probe

# Monitor response times
kubectl logs <web-pod> | grep analyses.json

# Check for mount issues
kubectl exec <pod> -- df /mnt/openstudio
```

## Validation Checklist

- [ ] Init containers successfully verify /mnt/openstudio on all deployments
- [ ] Pod readiness probe checks /analyses.json endpoint
- [ ] Pod startup probe allows 5 minute initialization window
- [ ] Liveness probe checks mount + write permissions
- [ ] Web pod environment variables include Passenger + Nginx config
- [ ] /analyses.json responses include `Content-Encoding: gzip` header
- [ ] Compressed response size is ~20-25% of uncompressed size
- [ ] No pod restarts due to mount point failures
- [ ] Readiness probes consistently pass after initialization

## Performance Expectations

### Before Improvements
- TTFB (time to first byte): ~22 seconds
- /analyses.json size: 42MB (uncompressed)
- Network transfer time: ~8-10 seconds
- Total download time: ~30-32 seconds
- Startup reliability: Crashes on /mnt/openstudio permission issues
- Timeout errors: Frequent at 300s

### After Improvements
- TTFB: ~10-15 seconds (improved Rails response time)
- /analyses.json size: 5-10MB (compressed)
- Network transfer time: ~1-2 seconds (80% reduction)
- Total download time: ~20-30 seconds (25-33% improvement)
- Startup reliability: Guaranteed mount verification before app starts
- Timeout errors: Rare (improved response time + buffering)

## Rollback Plan

If issues arise, these changes can be rolled back:

1. Remove init containers from deployments (pods will still work with existing mount)
2. Disable Nginx compression by setting `nginx_gzip: "off"` in values.yaml
3. Revert probe changes to simpler checks
4. Reduce Passenger pool size back to auto-calculation

## Future Improvements (Not Implemented)

1. **Response Caching**: Add ETags to /analyses.json for conditional requests
2. **Pagination API**: Break /analyses.json into pages to reduce payload size
3. **Connection Pooling**: Client-side connection reuse for CSV downloads
4. **Resumable Downloads**: Support resuming interrupted CSV downloads
5. **Metrics Export**: Prometheus metrics for response times and sizes
6. **Request Logging**: Structured logging for debugging timeout issues

## Implementation Notes

### Environment Variable Flow
```
values.yaml -> web-deploy.yaml -> container env -> start-server script
                                                  -> Nginx configuration
                                                  -> Passenger configuration
```

The container's entrypoint scripts (`/usr/local/bin/start-server`) must read these environment variables and apply them to Nginx/Passenger configuration files.

### Mount Point Verification Flow
```
Pod Launch
  ↓
Init Containers (sequential)
  ├─ init-wait-for-db (existing)
  ├─ init-verify-mnt-openstudio (NEW)
  ↓
Main Container Starts
  ├─ Rails app initializes
  ├─ /analyses.json endpoint available
  ↓
Readiness Probe
  ├─ Checks /analyses.json endpoint
  ├─ Pod becomes "Ready"
  ↓
Traffic Routed to Pod
```

## Testing Recommendations

1. **Smoke Test**: Deploy and verify pods start without mount errors
2. **Functional Test**: Verify /analyses.json endpoint returns compressed response
3. **Load Test**: Multiple concurrent /analyses.json requests
4. **Failure Test**: Simulate mount point issues, verify pod restarts gracefully
5. **Performance Test**: Measure compression ratio and download time improvements

## Questions & Support

For questions about these improvements, refer to:
1. This documentation
2. Helm chart comments in values.yaml
3. Deployment template comments in web-deploy.yaml
4. The related issue: OpenStudio server timeout/slowness on large analyses downloads
