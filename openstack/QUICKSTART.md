# OpenStudio Server on OpenStack - Quick Start

This guide prioritizes the OpenStack-managed Kubernetes path (for example Azimuth). The self-managed Terraform/OpenTofu + Kubespray flow in this directory is legacy and may not work in all environments.

> [!WARNING]
> Legacy self-managed scripts in `openstack/` are not actively tested. Use at your own risk.

## Recommended Prerequisites

- Access to a Kubernetes cluster created/managed by your OpenStack platform team (for example via Azimuth)
- kubectl installed
- Helm installed

OpenStack RC credentials are only required when you run OpenStack API/CLI automation
(`openstack` CLI, OpenTofu/Terraform in `openstack/`). They are not required for Helm-only
application deploys when your kubeconfig is already configured.

## 🚀 Recommended Deployment (Managed Kubernetes)

Once your cluster is created and kubeconfig is configured:

```bash
cp ../openstudio-server/values.production.template.yaml ../openstudio-server/values.yaml
# edit ../openstudio-server/values.yaml (provider=openstack, resources, storage, and secret name)
kubectl -n openstudio-server create secret generic openstudio-app-secrets \
  --from-literal=db-username="openstudio" \
  --from-literal=db-password="replace-with-strong-password" \
  --from-literal=redis-password="replace-with-strong-password" \
  --from-literal=web-secret-key="replace-with-long-random-secret"
helm upgrade --install openstudio-server ../openstudio-server -f ../openstudio-server/values.yaml
```

Before running Helm, do a storage quota preflight for Cinder-backed claims:

```text
nfs-server-provisioner.persistence.size
+ db.persistence.size
+ redis.persistence.size
+ existing in-use Cinder GB
<= Cinder quota GB
```

If over quota, reduce requested sizes first. Otherwise `nfs-pvc-data` can fail with `413 VolumeSizeExceedsAvailableQuota`, which cascades into pending `nfs-pvc`, then pending `web`, `web-background`, and `rserve`.

Use the local zot registry endpoint for NFS provisioner pulls:

```yaml
nfs-server-provisioner:
  image:
    repository: "erezsh2/nfs-provisioner"
    tag: "v2.3.0"
```

For private registries/mirrors, add overrides in your values file:

```yaml
global:
  images:
    registry: "registry.<your-domain>"
    repositoryPrefix: "proxy-cache" # optional
    org: "nrel"
    serverRepository: "openstudio-server"
    rserveRepository: "openstudio-rserve"
    tag: "3.10.0"
  imagePullSecrets: []
```

For the tracked Pulp registry profile (`pulp-dev.hpc.nlr.gov`), registry credentials and image pull secrets are not required.

`global.images.registry` is the central registry host and must include a valid host (for example `172.29.166.222:5000`), not a bare token such as `zot`.

`secrets.validateExistingSecret` is strict by default when using `secrets.existingSecret`. For offline render-only checks, use `--set secrets.validateExistingSecret=false`.

All tracked values files in this repository are templates. Keep real credentials in a local untracked values file and Kubernetes Secret.

The production template sets OpenStack storage hardening defaults:

- `nfs-server-provisioner.persistence.size: 1Ti`
- `db.persistence.storageClass: csi-cinder`
- `redis.persistence.storageClass: csi-cinder`
- `global.storageClasses.block: csi-cinder` (override this if your Cinder class name differs)

## Legacy Self-Managed Deployment (Optional, Untested)

If you explicitly choose to run self-managed cluster automation from this directory:

```bash
# Required before deploy-openstudio-cluster.sh:
kubectl -n openstudio-server create secret generic openstudio-app-secrets \
  --from-literal=db-username="openstudio" \
  --from-literal=db-password="replace-with-strong-password" \
  --from-literal=redis-password="replace-with-strong-password" \
  --from-literal=web-secret-key="replace-with-long-random-secret"

./deploy-openstudio-cluster.sh small
```

This flow provisions and bootstraps Kubernetes directly on OpenStack, but it is a legacy path and may require substantial environment-specific troubleshooting.
By default it applies `./values-openstack.yaml`, enforces `global.provider.name=openstack`, and requires `APP_SECRET_NAME` (default `openstudio-app-secrets`) to already exist.
It now also validates that `APP_SECRET_NAME` includes non-empty `db-username`, `db-password`, `redis-password`, and `web-secret-key` values before running Helm.

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
  helm upgrade --install openstudio-server ./openstudio-server
```

## Deploy OpenStudio Helm Chart

After the Kubernetes cluster is ready:

```bash
cd ../helm
helm upgrade --install openstudio-server ./openstudio-server
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

### Managed-Cluster Quick Triage (Image Pull Failures)

When using an OpenStack-managed Kubernetes cluster (for example Azimuth), start with:

```bash
kubectl -n openstudio-server get deploy worker -o wide
kubectl -n openstudio-server get pods -l app=worker --no-headers | awk '{print $3}' | sort | uniq -c
kubectl -n openstudio-server get events --sort-by=.lastTimestamp | tail -n 120
```

If events show repeated `ErrImagePull`/`ImagePullBackOff` with `401 UNAUTHORIZED` on mirrored image paths:

1. Verify registry settings and node-level registry auth for the target registry (Pulp profile does not require image pull secrets).
2. Confirm init container images are also pullable/cached (not only main containers).
3. Use `IfNotPresent` as a temporary mitigation while fixing registry mirror auth.
4. Restart only affected deployments and re-check pod status distribution.

If you use `kubectl debug` during incident response, pick an image that is already cached on the node and set `--image-pull-policy=Never`.

Recommended hardening values for managed OpenStack clusters:

```yaml
web:
  initContainer:
    imagePullPolicy: ""
  container:
    imagePullPolicy: ""
web_background:
  container:
    imagePullPolicy: ""
worker:
  container:
    imagePullPolicy: ""
prepull:
  enabled: false # set true temporarily for image warmup
  role: ""
  includeRserve: true
  includeWebInit: true
```

Provider-aware default for empty pull policy is `IfNotPresent` on OpenStack.

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

   TLS defaults are CA-first. The setup scripts now keep TLS verification enabled and set `tls-server-name` (default `kubernetes`).
   Override behavior with:

   ```bash
   KUBE_TLS_SERVER_NAME=<server-name-in-apiserver-cert> ./setup-kubectl.sh
   OPENSTACK_ALLOW_INSECURE_KUBECTL=true ./setup-kubectl.sh   # opt-in only
   ```

## Common Issues

### SSH Connection Timeouts

- **Cause:** Network policies blocking floating IP ranges (10.60.x.x)
- **Solution:** Check with network administrator or try from different network

### DNS Resolution Issues

- **Cause:** Instances can't reach DNS servers (10.60.10.240, 10.20.49.97)
- **Solution:** Check the Azimuth-managed cluster's node DNS or CoreDNS upstream configuration

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
