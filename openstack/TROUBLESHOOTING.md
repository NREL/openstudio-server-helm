# Troubleshooting Guide: OpenStudio Server on OpenStack

This guide covers common issues encountered when deploying OpenStudio Server on OpenStack with Kubernetes and their solutions.

> [!WARNING]
> This troubleshooting content is for the legacy self-managed OpenStack Kubernetes path in `openstack/`. That path is not actively tested; prefer managed Kubernetes (for example Azimuth) when available.

## 🚨 Critical Issues and Solutions

### 0. Analyses fail before simulation start (MongoDB on NFS)

**Symptoms:**

- Analyses are accepted but fail during initialization before any simulation jobs run.
- `web-background` logs include:
  - `lhs.rb failed with [8]: 1: Operation not permitted (on db:27017...)`
- `db` (MongoDB) logs include WiredTiger errors:
  - `__posix_open_file ... /data/db/collection-<n>...wt ... Operation not permitted`
  - New `collection-*.wt` files may appear as zero-byte files.

**Root Cause:**

- MongoDB/WiredTiger is running on an NFS-backed PVC (`storageClass: nfs`), which is not a safe backend for this workload in this environment.

**Diagnosis:**

```bash
# Check DB/Redis PVC backing classes
kubectl get pvc -n openstudio-server

# Confirm PV storage classes
kubectl get pv | grep -E "openstudio-server/(db|redis)"

# Confirm app-side failure signatures
kubectl logs -n openstudio-server deploy/web-background --tail=200 | \
  grep -E "Operation not permitted|lhs\\.rb failed"

# Confirm MongoDB-side WiredTiger failures
kubectl logs -n openstudio-server deploy/db --tail=200 | \
  grep -E "WiredTiger|Operation not permitted|__posix_open_file"
```

**Fix:**

1. Set DB/Redis persistence to block storage in values:
   - `db.persistence.storageClass: csi-cinder`
   - `redis.persistence.storageClass: csi-cinder`
2. Migrate DB/Redis PVCs (requires downtime for those services):
   - scale down `db` and `redis`
   - delete old DB/Redis PVCs
   - run `helm upgrade` with corrected values (and desired sizes)
3. Verify:
   - new DB/Redis PVCs are `csi-cinder`
   - no new WiredTiger `Operation not permitted` messages
   - new analyses move past initialization into queued/running stages

**Prevention (preflight before every upgrade):**

```bash
# Render-time values check
grep -nE "db:|redis:|storageClass" ./openstudio-server/values*.yaml

# Runtime check (live cluster)
kubectl get pvc -n openstudio-server
kubectl get pv | grep -E "openstudio-server/(db|redis|nfs-pvc|nfs-pvc-data)"
```

### 0b. Web starts failing with Mongo auth errors after DB/image churn

**Symptoms:**

- `web` logs show:
  - `Mongo::Auth::Unauthorized`
  - `Authentication failed`
  - `UserNotFound: Could not find user "openstudio" for db "admin"`
- `web` readiness never turns healthy, and analyses do not progress into `simulations`.

**Root Cause:**

- MongoDB auth user state drifted after DB image/PVC churn (for example temporary image swaps or partial reinitialization).

**Diagnosis:**

```bash
kubectl logs -n openstudio-server deploy/web --tail=200 | \
  grep -E "Mongo::Auth::Unauthorized|Authentication failed|UserNotFound"
```

**Fix (restore expected admin user from app secret):**

```bash
DB_PASS=$(kubectl -n openstudio-server get secret openstudio-app-secrets \
  -o jsonpath='{.data.db-password}' | base64 --decode)

kubectl -n openstudio-server exec deploy/db -- env DB_PASS="$DB_PASS" \
  mongosh --quiet --eval '
    const admin = db.getSiblingDB("admin");
    const user = "openstudio";
    const existing = admin.getUser(user);
    if (!existing) {
      admin.createUser({user, pwd: process.env.DB_PASS, roles:[{role:"root", db:"admin"}]});
    } else {
      admin.updateUser(user, {pwd: process.env.DB_PASS, roles:[{role:"root", db:"admin"}]});
    }
  '

kubectl -n openstudio-server rollout restart deploy/web
```

**Prevention:**

- Avoid image-family churn for live DB PVCs (for example `mongo` ↔ `bitnami/mongodb`) without an explicit migration plan.

### 1. Pod Network Isolation (Most Common Issue)

**Symptoms:**

- Pods cannot reach the Kubernetes API server (10.96.0.1:443)
- CSI drivers fail to provision volumes
- NFS provisioner logs show "context deadline exceeded" or timeouts
- Services can't be reached from pods

**Root Cause:**
OpenStack network configurations often isolate pod networks (10.244.0.0/16) from service networks (10.96.0.0/12) and external connectivity.

**Solution:**
Apply `hostNetwork: true` to affected deployments:

```bash
# NFS provisioner (automatically done by bootstrap script)
kubectl patch deployment nfs-subdir-external-provisioner -n kube-system \
  -p '{"spec":{"template":{"spec":{"hostNetwork":true}}}}'

# CSI driver controller (if using Cinder CSI)
kubectl patch deployment csi-cinder-controllerplugin -n kube-system \
  -p '{"spec":{"template":{"spec":{"hostNetwork":true}}}}'

# Any custom provisioner
kubectl patch deployment <deployment-name> -n <namespace> \
  -p '{"spec":{"template":{"spec":{"hostNetwork":true}}}}'
```

**Prevention:**
Ensure the bootstrap script applies these patches automatically.

### 2. Storage Provisioning Failures

**Symptoms:**

- PVCs stuck in "Pending" state
- Events show "Waiting for a volume to be created"
- Storage provisioner pods are failing or restarting
- Cinder events include `413 VolumeSizeExceedsAvailableQuota`

**Diagnosis:**

```bash
# Check storage classes
kubectl get storageclass

# Check PVC status
kubectl describe pvc <pvc-name>

# Check provisioner status
kubectl get pods -n kube-system -l app=nfs-subdir-external-provisioner

# Check provisioner logs
kubectl logs -n kube-system -l app=nfs-subdir-external-provisioner
```

**Solutions:**

#### For NFS Storage Issues:

```bash
# Verify NFS server on master
MASTER_IP=$(terraform output -raw master_floating_ip)
ssh ubuntu@$MASTER_IP "systemctl status nfs-server"
ssh ubuntu@$MASTER_IP "showmount -e localhost"

# Test NFS connectivity from other nodes
WEB_IP=$(terraform output -json web_floating_ips | jq -r '.[0]')
MASTER_INTERNAL_IP=$(terraform output -raw master_ip)
ssh ubuntu@$WEB_IP "showmount -e $MASTER_INTERNAL_IP"

# Restart NFS services if needed
ssh ubuntu@$MASTER_IP "sudo systemctl restart nfs-server && sudo exportfs -ra"

# Check NFS provisioner has hostNetwork
kubectl get deployment nfs-subdir-external-provisioner -n kube-system -o yaml | grep -A5 -B5 hostNetwork
```

#### For Cinder CSI Issues (if still using):

```bash
# Check CSI driver pods
kubectl get pods -n kube-system | grep csi-cinder

# Check OpenStack credentials
kubectl get secret cloud-config -n kube-system -o yaml

# Test OpenStack connectivity from CSI pod
kubectl exec -n kube-system <csi-pod-name> -- curl -k <openstack-auth-url>
```

#### For Cinder Quota Exhaustion (`413 VolumeSizeExceedsAvailableQuota`)

This is a claim-sizing issue, not a scheduler issue.

**Typical cascade:**

1. `nfs-pvc-data` fails to provision on `csi-cinder` due to quota.
2. `openstudio-server-nfs-server-provisioner` stays `Pending` (depends on `nfs-pvc-data`).
3. `nfs-pvc` stays `Pending` (external provisioner unavailable).
4. `web`, `web-background`, and `rserve` stay `Pending` with unbound PVC errors.

**Fix:**

1. Lower requested values in Helm values:
   - `nfs-server-provisioner.persistence.size`
   - `db.persistence.size`
   - `redis.persistence.size`
2. Ensure the sum of requested claims plus current in-use Cinder GB is below quota.
3. Recreate pending PVCs (`nfs-pvc-data`, `nfs-pvc`) and re-run Helm upgrade/install.

#### For StorageClass Name Mismatch:

If events show errors like:

- `storageclass.storage.k8s.io "csi-cinder" not found`

your chart values are likely using the wrong Cinder StorageClass name for this cluster.

```bash
kubectl get storageclass
kubectl get pvc -A
```

Set the OpenStack block class explicitly in values and redeploy:

```yaml
global:
  storageClasses:
    block: csi-cinder
```

### 3. Container Image Pull Failures

**Symptoms:**

- Pods stuck in "ImagePullBackOff" or "ErrImagePull"
- Long delays downloading container images
- TLS handshake failures or certificate errors

**Diagnosis:**

```bash
# Check pod events
kubectl describe pod <pod-name>

# Check containerd configuration
ssh ubuntu@<node-ip> "cat /etc/containerd/config.toml"

# Check corporate firewall detection
ssh ubuntu@<node-ip> "cat /etc/corporate-firewall-status"

# Test registry connectivity
ssh ubuntu@<node-ip> "curl -I https://registry-1.docker.io/v2/"
```

If the event stream shows registry URLs rewritten through `quay.io/v2/azimuth/...`, the node runtime has an active mirror/proxy configuration. Helm values cannot override that; remove or correct the containerd mirror config on the affected nodes.

**Solutions:**

#### Manual Registry Configuration:

```bash
# Update containerd config with TLS skip (if corporate firewall detected)
ssh ubuntu@<node-ip> "sudo tee /etc/containerd/config.toml << 'EOF'
version = 2

[plugins]
  [plugins.\"io.containerd.grpc.v1.cri\"]
    [plugins.\"io.containerd.grpc.v1.cri\".registry]
      [plugins.\"io.containerd.grpc.v1.cri\".registry.configs]
        [plugins.\"io.containerd.grpc.v1.cri\".registry.configs.\"registry-1.docker.io\".tls]
          insecure_skip_verify = true
        [plugins.\"io.containerd.grpc.v1.cri\".registry.configs.\"quay.io\".tls]
          insecure_skip_verify = true
EOF"

# Restart containerd
ssh ubuntu@<node-ip> "sudo systemctl restart containerd"
```

### 8. LoadBalancer Sync Errors (`SyncLoadBalancerFailed`)

**Symptoms:**

- Service events show repeated `SyncLoadBalancerFailed` / `UpdateLoadBalancerFailed`.
- Error payload includes Octavia `500` with fault strings referencing unreachable Neutron/security-group endpoints.

**Diagnosis:**

```bash
kubectl describe svc -n openstudio-server ingress-load-balancer
kubectl get events -n openstudio-server \
  --field-selector involvedObject.kind=Service,involvedObject.name=ingress-load-balancer \
  --sort-by=.lastTimestamp
kubectl logs -n openstack-system -l app=openstack-cloud-controller-manager --since=60m | \
  grep -E 'ingress-load-balancer|SyncLoadBalancerFailed|EnsuredLoadBalancer|faultstring'
```

**Interpretation:**

1. If service has external IP + LB ID annotation and CCM logs show `EnsuredLoadBalancer`, earlier warnings were transient and can be ignored.
2. If failures persist and fault strings show wrong/unreachable OpenStack endpoints (for example `vs-api.hpc.nlr.gov`), this is a platform endpoint/DNS issue in OpenStack/CCM config.

**Fix:**

1. Platform team updates OpenStack LB/Neutron endpoint config and DNS reachability.
2. Reconcile the service by re-applying or patching it (or restarting CCM if instructed by platform team).

When validating worker scale changes, also watch `ingress-load-balancer` service events. A few transient `SyncLoadBalancerFailed` or Octavia `503 Service Unavailable` events can happen during node membership churn; repeated events over multiple checks mean the platform team should investigate before further scaling. Use the report-only quiet-window gate before each cap bump:

```bash
./scripts/openstudio-reliability --mode ceiling-probe \
  --quiet-window-seconds 900 \
  --quiet-interval-seconds 30 \
  --probe-step-replicas 50
```

#### Pre-pull Critical Images:

```bash
# Pre-pull images on all nodes
NODES=$(kubectl get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="ExternalIP")].address}')
for node in $NODES; do
  ssh ubuntu@$node "sudo crictl pull registry.k8s.io/pause:3.9"
  ssh ubuntu@$node "sudo crictl pull 172.29.166.222:5000/nrel/openstudio-server:3.10.0"
  ssh ubuntu@$node "sudo crictl pull 172.29.166.222:5000/library/mongo:6.0.7"
  ssh ubuntu@$node "sudo crictl pull 172.29.166.222:5000/library/redis:6.0.9"
done
```

### 4. DNS Resolution Failures

**Symptoms:**

- Pods can't resolve service names
- External DNS lookups fail from pods
- CoreDNS pods are failing or restarting

**Diagnosis:**

```bash
# Check CoreDNS status
kubectl get pods -n kube-system -l k8s-app=kube-dns

# Test DNS from a pod
kubectl run test-pod --image=busybox --rm -it -- nslookup kubernetes.default.svc.cluster.local

# Check CoreDNS configuration
kubectl get configmap coredns -n kube-system -o yaml
```

**Solutions:**

#### Update CoreDNS Configuration:

```bash
# Get internal DNS servers (usually from /etc/resolv.conf on nodes)
INTERNAL_DNS=$(ssh ubuntu@<node-ip> "grep nameserver /etc/resolv.conf | head -1 | awk '{print \$2}'")

# Update CoreDNS config
kubectl edit configmap coredns -n kube-system
# Add/update the forward section:
# forward . $INTERNAL_DNS

# Restart CoreDNS
kubectl rollout restart deployment/coredns -n kube-system
```

### 5. Node Readiness Issues

**Symptoms:**

- Nodes stuck in "NotReady" state
- Kubelet service is not running
- Pods won't schedule to nodes

**Diagnosis:**

```bash
# Check node status
kubectl get nodes
kubectl describe node <node-name>

# Check kubelet status on node
ssh ubuntu@<node-ip> "systemctl status kubelet"
ssh ubuntu@<node-ip> "journalctl -u kubelet -f"

# Check network plugin
kubectl get pods -n kube-system -l k8s-app=flannel
```

**Solutions:**

#### Restart Node Services:

```bash
# Restart kubelet
ssh ubuntu@<node-ip> "sudo systemctl restart kubelet"

# Restart containerd
ssh ubuntu@<node-ip> "sudo systemctl restart containerd"

# Check for swap (must be disabled)
ssh ubuntu@<node-ip> "sudo swapoff -a"
```

#### Fix Network Plugin Issues:

```bash
# Reinstall Flannel if needed
kubectl delete -f https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml
kubectl apply -f https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml

# Or use a known working version
kubectl apply -f https://raw.githubusercontent.com/flannel-io/flannel/v0.20.2/Documentation/kube-flannel.yml
```

### 6. Helm Release Stuck in Failed State (Managed-Field Conflicts)

**Symptoms:**

- `helm status` reports `STATUS: failed`
- Description contains conflict errors against fields such as:
  - `Deployment/worker .spec.replicas`
  - `HorizontalPodAutoscaler/worker .spec.maxReplicas`
- Runtime workloads still appear healthy and continue processing jobs

**Diagnosis:**

```bash
helm status openstudio-server -n openstudio-server
helm history openstudio-server -n openstudio-server
kubectl -n openstudio-server get deploy worker -o wide
kubectl -n openstudio-server get hpa worker -o wide
```

**Guarded Reconcile Path (use only for conflict failures):**

```bash
# Prefer automated helper
./scripts/openstudio-reliability --mode reconcile-helm --apply --allow-chart-apply

# Equivalent direct command
helm upgrade openstudio-server ./openstudio-server \
  -n openstudio-server \
  --reuse-values \
  --server-side=false \
  --description "Reconcile release after managed-field conflicts"
```

Do **not** run reconcile if the release failed for non-conflict reasons, or while workloads are unstable.
If reconcile causes regressions, roll back immediately:

```bash
helm rollback openstudio-server <last-good-revision> -n openstudio-server
```

**Prevention:**

- Standardize on one operational reconcile path and avoid ad-hoc mixed apply methods.
- Use `./scripts/openstudio-reliability --mode check` before and after upgrades.
- Keep a queue/job snapshot before mutation:
  - `./scripts/openstudio-reliability --mode snapshot --snapshot-dir <path>`

### 7. Analyses Stuck in `started` (Queue/State Divergence)

**Symptoms:**

- PAT/UI analyses remain in `started` for a long period.
- Redis queue depths are near zero, or `requeued` accumulates.
- Pods and Helm release appear healthy.

**Diagnosis:**

```bash
./scripts/openstudio-reliability --mode check --stale-minutes 70
./scripts/openstudio-reliability --mode snapshot \
  --stale-minutes 70 \
  --snapshot-dir ./incident-snapshots/openstudio-server-$(date +%Y%m%d-%H%M%S)
```

**Guarded Recovery (apply-gated):**

```bash
./scripts/openstudio-reliability --mode recover-stuck --stale-minutes 70 --apply
```

What recovery does:

- Ensures worker queue subscriptions include `simulations,requeued`.
- Requeues stale started datapoints for stale started analyses.
- Finalizes stale started `batch_run` jobs only if all datapoints are terminal.
- Prints post-recovery queue and divergence checks.

**Prevention:**

- Keep worker queues configured with `simulations,requeued`.
- Add alerts for stale started jobs/datapoints and non-zero `requeued` backlog.

### 8. Worker Ceiling Probe Requires Sustained Quiet Window

**Goal:**

- Raise worker `maxReplicas` only when a quiet-window probe reports healthy gates.

**Run report-only probe:**

```bash
./scripts/openstudio-reliability --mode ceiling-probe \
  --quiet-window-seconds 900 \
  --quiet-interval-seconds 30 \
  --probe-step-replicas 50
```

**Interpretation:**

1. `RECOMMENDATION=advance`: manually raise `worker_hpa.maxReplicas` by the recommended step and monitor convergence.
2. `RECOMMENDATION=hold`: do not raise ceiling; investigate blocker summaries (`HARD_BLOCKER_SAMPLES`, `QUEUE_BLOCKERS_TOTAL`, `CORE_SERVICE_BLOCKERS_TOTAL`).

**Operator sequence per ramp step:**

1. Run `--mode check`.
2. Run `--mode ceiling-probe`.
3. If probe recommends advance, apply one cap step and allow a settle window.
4. Re-run probe before the next cap step.

## 📊 Diagnostic Commands Reference

### Cluster Health Check

```bash
# Overall cluster status
kubectl cluster-info
kubectl get nodes
kubectl get pods --all-namespaces

# System pod health
kubectl get pods -n kube-system

# Storage health
kubectl get storageclass
kubectl get pv
kubectl get pvc --all-namespaces
```

### Network Diagnostics

```bash
# Test pod-to-pod networking
kubectl run test1 --image=nginx
kubectl run test2 --image=nginx
kubectl exec -it test1 -- ping $(kubectl get pod test2 -o jsonpath='{.status.podIP}')

# Test service discovery
kubectl exec -it test1 -- nslookup kubernetes.default.svc.cluster.local

# Test external connectivity
kubectl exec -it test1 -- wget -qO- http://httpbin.org/ip
```

### Storage Diagnostics

```bash
# NFS server status
MASTER_IP=$(terraform output -raw master_floating_ip)
ssh ubuntu@$MASTER_IP "systemctl status nfs-server"
ssh ubuntu@$MASTER_IP "exportfs -v"

# Test NFS mount from worker node
WORKER_IP=$(terraform output -json worker_floating_ips | jq -r '.[0]')
MASTER_INTERNAL=$(terraform output -raw master_ip)
ssh ubuntu@$WORKER_IP "sudo mkdir -p /tmp/nfs-test"
ssh ubuntu@$WORKER_IP "sudo mount -t nfs $MASTER_INTERNAL:/srv/nfs/k8s-storage /tmp/nfs-test"
ssh ubuntu@$WORKER_IP "sudo umount /tmp/nfs-test"
```

### OpenStudio Server Diagnostics

```bash
# Pod status
kubectl get pods -n openstudio-test

# PVC status
kubectl get pvc -n openstudio-test

# Service status
kubectl get svc -n openstudio-test

# Events
kubectl get events -n openstudio-test --sort-by='.lastTimestamp'

# Detailed pod inspection
kubectl describe pod -n openstudio-test <pod-name>
kubectl logs -n openstudio-test <pod-name>
```

## 🔧 Recovery Procedures

### Complete Cluster Reset

If the cluster is in a bad state:

```bash
# 1. Clean up Kubernetes
ssh ubuntu@<master-ip> "sudo kubeadm reset -f"

# 2. Clean up on all nodes
for node_ip in <all-node-ips>; do
  ssh ubuntu@$node_ip "sudo systemctl stop kubelet containerd"
  ssh ubuntu@$node_ip "sudo rm -rf /etc/kubernetes /var/lib/kubelet /var/lib/etcd"
  ssh ubuntu@$node_ip "sudo systemctl start containerd"
done

# 3. Reinitialize cluster (run bootstrap script)
./bootstrap-k8s.sh
```

### Storage Reset

If NFS storage is corrupted:

```bash
# 1. Delete all PVCs first
kubectl delete pvc --all --all-namespaces

# 2. Clean NFS directory on master
MASTER_IP=$(terraform output -raw master_floating_ip)
ssh ubuntu@$MASTER_IP "sudo rm -rf /srv/nfs/k8s-storage/*"

# 3. Reinstall NFS provisioner
helm uninstall nfs-subdir-external-provisioner -n kube-system
# Then run the NFS setup from bootstrap script
```

### Infrastructure Reset

If OpenStack infrastructure is corrupted:

```bash
# 1. Destroy all resources
terraform destroy -auto-approve

# 2. Clean up any orphaned resources manually
openstack server list
openstack volume list
openstack network list

# 3. Redeploy
./deploy.sh
```

## 📝 Preventive Measures

### Regular Health Checks

```bash
# Create a health check script
cat > health-check.sh << 'EOF'
#!/bin/bash
echo "=== Cluster Health Check ==="
kubectl get nodes
echo "=== Storage Classes ==="
kubectl get storageclass
echo "=== System Pods ==="
kubectl get pods -n kube-system
echo "=== OpenStudio Pods ==="
kubectl get pods -n openstudio-test
echo "=== PVCs ==="
kubectl get pvc -n openstudio-test
echo "=== NFS Server Status ==="
MASTER_IP=$(terraform output -raw master_floating_ip)
ssh ubuntu@$MASTER_IP "systemctl is-active nfs-server"
EOF

chmod +x health-check.sh
./health-check.sh
```

### Monitoring Setup

```bash
# Set up basic monitoring for critical components
kubectl create namespace monitoring

# Monitor NFS server disk usage
ssh ubuntu@<master-ip> "df -h /srv/nfs/k8s-storage"

# Monitor provisioner health
kubectl get pods -n kube-system -l app=nfs-subdir-external-provisioner --watch
```

## 🆘 Emergency Contacts and Resources

### Log Locations

- **System logs**: `journalctl -u <service-name> -f`
- **Kubernetes logs**: `/var/log/pods/`
- **Container logs**: `crictl logs <container-id>`
- **Cloud-init logs**: `/var/log/cloud-init-output.log`

### Useful Resources

- [Kubernetes Troubleshooting](https://kubernetes.io/docs/tasks/debug-application-cluster/troubleshooting/)
- [OpenStack Documentation](https://docs.openstack.org/)
- [NFS Troubleshooting](https://linux.die.net/man/5/exports)

Remember: When in doubt, check the logs first! Most issues can be diagnosed by examining pod events (`kubectl describe pod`) and system logs (`journalctl`).

## OpenStack/Calico Networking Requirements (New)

When running Calico with IPIP encapsulation on OpenStack:

- Allow IP-in-IP (protocol 4) ingress/egress between node subnet CIDR
- Allow BGP (TCP/179) ingress/egress between node subnet CIDR

These are implemented in `openstack/additional-security-rules.tf` and reference `openstack_networking_subnet_v2.k8s_subnet.cidr` dynamically. Without them, you may see:

- NodeLocalDNS timeouts to CoreDNS Service IP
- calico-kube-controllers failing to reach API via 10.233.0.1
- Cross-node Service IPs intermittently unreachable

Post-bootstrap, `bootstrap-k8s.sh` now runs a networking healthcheck that validates CoreDNS/NodeLocalDNS and restarts them if needed.
