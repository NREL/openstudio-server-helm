# OpenStudio Server on OpenStack - Quick Start

This guide prioritizes the OpenStack-managed Kubernetes path (for example Azimuth). The self-managed Terraform/OpenTofu + Kubespray flow in this directory is legacy and may not work in all environments.

> [!WARNING]
> Legacy self-managed scripts in `openstack/` are not actively tested. Use at your own risk.

## Recommended Prerequisites

- Access to a Kubernetes cluster created/managed by your OpenStack platform team (for example via Azimuth)
- kubectl installed
- Helm installed

## 🚀 Recommended Deployment (Managed Kubernetes)

Once your cluster is created and kubeconfig is configured:

```bash
cp ../openstudio-server/values_production.templateyaml ../openstudio-server/values.yaml
# edit ../openstudio-server/values.yaml (provider=openstack, resources, storage, and secret name)
kubectl -n openstudio-server create secret generic openstudio-app-secrets \
  --from-literal=db-username="openstudio" \
  --from-literal=db-password="replace-with-strong-password" \
  --from-literal=redis-password="replace-with-strong-password" \
  --from-literal=web-secret-key="replace-with-long-random-secret"
helm upgrade --install openstudio-server ../openstudio-server -f ../openstudio-server/values.yaml
```

All tracked values files in this repository are templates. Keep real credentials in a local untracked values file and Kubernetes Secret.

The production template sets OpenStack storage hardening defaults:

- `nfs-server-provisioner.persistence.size: 1Ti`
- `db.persistence.storageClass: csi-cinder`
- `redis.persistence.storageClass: csi-cinder`
- `global.storageClasses.block: csi-cinder` (override this if your Cinder class name differs)

## Legacy Self-Managed Deployment (Optional, Untested)

If you explicitly choose to run self-managed cluster automation from this directory:

```bash
./deploy.sh
```

This flow provisions and bootstraps Kubernetes directly on OpenStack, but it is a legacy path and may require substantial environment-specific troubleshooting.

## Expected Output

```
===================================
OpenStudio Server K8s Deployment
===================================

[INFO] Checking prerequisites...
[SUCCESS] Prerequisites check passed
[INFO] Deploying OpenStack infrastructure with Terraform...
[SUCCESS] Infrastructure deployment completed
[INFO] Testing network connectivity to deployed instances...
[SUCCESS] SSH connectivity test successful
[INFO] Monitoring Kubernetes cluster bootstrap process...
[SUCCESS] All nodes are ready!
[INFO] Setting up kubectl configuration locally...
[SUCCESS] kubectl configuration completed
[SUCCESS] Cluster verification passed

===================================
DEPLOYMENT COMPLETED SUCCESSFULLY!
===================================

Cluster Information:
  Master IP: 10.60.124.23
  Cluster Name: openstudio-server
  Total Nodes: 3

kubectl is configured and ready to use:
  kubectl get nodes
  kubectl get pods --all-namespaces

To deploy OpenStudio Helm chart:
  cd ../helm
  helm install openstudio-server ./openstudio-server
```

## Deploy OpenStudio Helm Chart

After the Kubernetes cluster is ready:

```bash
cd ../helm
helm install openstudio-server ./openstudio-server
```

## Verify Deployment

Check cluster status:
```bash
kubectl get nodes
kubectl get pods --all-namespaces
```

## Troubleshooting

If you encounter issues:

```bash
# Show current status and troubleshooting info
./deploy.sh troubleshoot

# Destroy and redeploy
./deploy.sh destroy
./deploy.sh
```

## Manual Steps (If Needed)

If the automated deployment encounters connectivity issues:

1. **Check network connectivity:**
   ```bash
   ping <master-floating-ip>
   ssh ubuntu@<master-floating-ip>
   ```

2. **Monitor bootstrap process manually:**
   ```bash
   ./bootstrap-k8s.sh
   ```

3. **Setup kubectl manually:**
   ```bash
   ./setup-kubectl.sh
   ```

## Common Issues

### SSH Connection Timeouts
- **Cause:** Network policies blocking floating IP ranges (10.60.x.x)
- **Solution:** Check with network administrator or try from different network

### DNS Resolution Issues
- **Cause:** Instances can't reach DNS servers (10.60.10.240, 10.20.49.97)
- **Solution:** Check OpenStack network configuration

### Cloud-init Bootstrap Failures
- **Cause:** Package download failures, network issues
- **Solution:** Check console logs:
  ```bash
  openstack console log show openstudio-server-master
  ```

## Architecture

The automated deployment creates:

- **Master Node (1x):** Kubernetes control plane + CSI driver
- **Worker Node (1x):** Kubernetes worker for general workloads  
- **Web Node (1x):** Labeled for web frontend workloads
- **Storage:** Cinder CSI driver for persistent volumes
- **Networking:** Private network with router and floating IPs
- **Security:** Security groups with minimal required ports

## Total Deployment Time

- **Infrastructure:** ~2-3 minutes
- **Kubernetes Bootstrap:** ~8-12 minutes
- **Total:** ~10-15 minutes

## Next Steps

Once deployment is complete:

1. Deploy OpenStudio Helm chart
2. Access web interface via LoadBalancer or NodePort
3. Run OpenStudio simulations
4. Scale workers as needed

## Advanced Usage

```bash
# Show all available commands
./deploy.sh help

# Show detailed status
./deploy.sh status

# Destroy infrastructure
./deploy.sh destroy
```

---

**Success Criteria:** After running `./deploy.sh`, you should have a working 3-node Kubernetes cluster with kubectl configured and ready to deploy the OpenStudio Helm chart.
