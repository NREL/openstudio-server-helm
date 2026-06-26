# OpenStudio Server on OpenStack (Legacy Self-Managed Cluster Path)

This directory contains legacy automation for building a Kubernetes cluster directly on OpenStack (Terraform/OpenTofu + Kubespray), then deploying OpenStudio Server.

> [!WARNING]
> This self-managed OpenStack cluster path is **not actively tested** and may not work in all environments.
> Prefer a Kubernetes cluster created and managed by your OpenStack platform team (for example via **Azimuth**), then use this repository only for Helm deployment.

## Recommended Approach (Azimuth or Admin-Managed Kubernetes)

1. Create a Kubernetes cluster using your OpenStack-managed platform (for example Azimuth).
2. Configure local kubeconfig access to that cluster.
3. Deploy OpenStudio Server using this repository's Helm chart and values templates.

```bash
# Option A: start from the tracked baseline values.yaml
# Option B: copy production template to a local override file
cp ../openstudio-server/values_production.templateyaml ../openstudio-server/values.local.yaml
# Create the namespace if haven't already
kubectl create namespace openstudio-server
# Edit your values file (resources/provider=openstack/storage classes/secret name)
kubectl -n openstudio-server create secret generic openstudio-app-secrets \
  --from-literal=db-username="openstudio" \
  --from-literal=db-password="replace-with-strong-password" \
  --from-literal=redis-password="replace-with-strong-password" \
  --from-literal=web-secret-key="replace-with-long-random-secret"
helm install openstudio-server ./openstudio-server \
  -f ./openstudio-server/values.yaml -n openstudio-server
```

Before `helm install` / `helm upgrade`, perform a Cinder quota preflight for requested PVC sizes:

```text
nfs-server-provisioner.persistence.size
+ db.persistence.size
+ redis.persistence.size
+ existing in-use Cinder GB
<= Cinder quota GB
```

If over quota, lower requested sizes first. A failed `nfs-pvc-data` claim blocks the in-cluster NFS provisioner, which then blocks `nfs-pvc` and keeps `web`, `web-background`, and `rserve` pending.

## Legacy Quick Start (Use at Your Own Risk)

If you still need to self-manage Kubernetes on OpenStack with the scripts in this directory:

```bash
# Pre-create app secret used by deploy-openstudio-cluster.sh
kubectl -n openstudio-server create secret generic openstudio-app-secrets \
  --from-literal=db-username="openstudio" \
  --from-literal=db-password="replace-with-strong-password" \
  --from-literal=redis-password="replace-with-strong-password" \
  --from-literal=web-secret-key="replace-with-long-random-secret"

./deploy-openstudio-cluster.sh small
```

By default, `deploy-openstudio-cluster.sh` deploys with:

- `HELM_VALUES_FILE=./values-openstack.yaml`
- `APP_SECRET_NAME=openstudio-app-secrets`
- `global.provider.name=openstack`

## Legacy Path Features

- **🔐 Corporate Firewall Support**: Automatic detection and workaround for certificate interception
- **⚡ One-Click Deployment**: Automated infrastructure, Kubernetes, and application deployment
- **📏 Multiple Cluster Sizes**: Small, large, and test configurations
- **🏷️ Node Workload Separation**: Dedicated web and worker node groups with proper tainting
- **💾 Storage Integration**: Cinder CSI driver with multiple storage classes
- **🌐 LoadBalancer Support**: Octavia integration for external service exposure
- **🔧 EKS Compatibility**: Matches AWS EKS configuration patterns for consistency

The legacy self-managed OpenStack overlays (`values-openstack*.yaml`) pin
`global.nodeGroups` to `nodegroup=web-group|worker-group` and add the matching
`NoSchedule` tolerations so workloads can land on Kubespray-tainted nodes.

## 📋 Prerequisites

### Required Tools

- [OpenTofu](https://opentofu.org/) (Terraform alternative)
- [Ansible](https://ansible.com/)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [Helm](https://helm.sh/)
- SSH access with key-based authentication

### OpenStack Environment Variables

```bash
export TF_VAR_openstack_user_name="your-username"
export TF_VAR_openstack_password="your-password"
export TF_VAR_openstack_auth_url="https://your-openstack-api:5000"
export TF_VAR_openstack_tenant_name="your-project"
export TF_VAR_openstack_user_domain_name="your-domain"
export TF_VAR_openstack_project_domain_id="your-project-domain-id"
export TF_VAR_openstack_project_id="your-project-id"
export TF_VAR_openstack_region="RegionOne"
export TF_VAR_key_pair="your-openstack-keypair-name"
export TF_VAR_public_key="$(cat ~/.ssh/id_rsa.pub)"

# Optional hardening: narrow these CIDRs instead of permissive defaults.
export TF_VAR_admin_access_cidr="203.0.113.10/32"
export TF_VAR_k8s_api_access_cidr="203.0.113.10/32"
export TF_VAR_nodeport_access_cidr="0.0.0.0/0"
```

OpenStack RC credentials are required for OpenStack API operations in this directory
(for example `openstack token issue`, OpenTofu/Terraform provisioning). They are not
required for Helm-only upgrades to an already-accessible Kubernetes cluster.

### Internal Registry / Mirror Configuration

Use the path that matches how the cluster was created:

1. **Azimuth-managed OpenStack Kubernetes**: use the chart registry profile plus production overrides.
2. **Bare OpenStack / legacy self-managed Kubernetes**: use the node bootstrap path in `openstack/k8s-cloud-init.yaml` and `openstack/values-openstack.yaml`.

For managed Azimuth clusters, the recommended pattern is to use an internal registry or Harbor
proxy cache and point chart images at it. Start from `openstudio-server/values.registry-live.yaml`
and pair it with `openstudio-server/values_production.templateyaml` or a local production override:

```bash
cp openstudio-server/values.registry-live.yaml openstudio-server/values.local.yaml
```

Core registry settings:

```yaml
global:
  images:
    registry: "registry.<ingress-base-domain>"
    repositoryPrefix: "proxy-cache" # optional
    org: "nrel"
    serverRepository: "openstudio-server"
    rserveRepository: "openstudio-rserve"
    tag: "3.10.0"
  imagePullSecrets:
    - "registry-credentials"
```

`global.images.registry` must be a registry host/FQDN (optionally with port). Avoid bare names like `zot`, which are interpreted as Docker Hub namespaces by container runtimes.

You can also use a dedicated workload ServiceAccount with image pull secrets:

```yaml
serviceAccount:
  create: true
  name: "openstudio-workload"
  imagePullSecrets:
    - "registry-credentials"
```

For OpenStack clusters, set pull policies to favor cached images and avoid repeated mirror fetches:

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
```

`""` uses chart defaults (OpenStack => `IfNotPresent`, other providers => `Always`).

For planned scale events/upgrades, optionally pre-warm node caches:

```yaml
prepull:
  enabled: true
  role: "" # "", "web", or "worker"
  includeRserve: true
  includeWebInit: true
```

After warmup completes, set `prepull.enabled: false` to remove the DaemonSet.

You can apply the same profile through the install helper:

```bash
PROVIDER=openstack \
REGISTRY_PROFILE=true \
REGISTRY_VALUES_FILE=./openstudio-server/values.registry-live.yaml \
REGISTRY_PULL_SECRET_NAME=registry-credentials \
./scripts/install.sh
```

For Azimuth production workloads, use `worker_hpa.maxReplicas: 1443` only if the cluster
capacity and node density can support it.

## 🏗️ Cluster Configurations

### Small Cluster (Development/Testing)

- **Master**: 1x CS.Wee (8 vCPU, 32GB RAM)
- **Web Nodes**: 2x CS.Medium (16 vCPU, 64GB RAM each)
- **Worker Nodes**: 1x CM.Large (32 vCPU, 64GB RAM)
- **Storage**: 100GB per node

```bash
./deploy-openstudio-cluster.sh small
```

### Large Cluster (Production)

- **Master**: 1x CS.Large (16 vCPU, 64GB RAM)
- **Web Nodes**: 1x CS.2XMedium (32 vCPU, 128GB RAM)
- **Worker Nodes**: 1x CM.2XLarge (64 vCPU, 256GB RAM)
- **Storage**: 550GB per node

```bash
./deploy-openstudio-cluster.sh large
```

### Test Cluster (Single Node)

- **Master**: 1x CS.Wee (8 vCPU, 32GB RAM)
- **Storage**: 100GB

```bash
./deploy-openstudio-cluster.sh test
```

## 🎯 Usage Examples

### Basic Deployment

```bash
# Deploy small cluster
./deploy-openstudio-cluster.sh small

# Deploy large cluster with cleanup
./deploy-openstudio-cluster.sh large --cleanup

# Deploy test cluster without Helm (infrastructure only)
./deploy-openstudio-cluster.sh test --skip-helm

# Use a custom values overlay and secret name
HELM_VALUES_FILE=./values-openstack-nfs.yaml APP_SECRET_NAME=openstudio-app-secrets \
  ./deploy-openstudio-cluster.sh small
```

### Advanced Options

```bash
# Skip Terraform (use existing infrastructure)
./deploy-openstudio-cluster.sh small --skip-terraform

# Skip Kubespray (use existing Kubernetes)
./deploy-openstudio-cluster.sh small --skip-kubespray --skip-terraform

# Verbose output for debugging
./deploy-openstudio-cluster.sh small --verbose
```

## 🔧 Manual Deployment Steps

If you prefer manual control, you can run each step individually:

### 1. Infrastructure Deployment

```bash
# Initialize Terraform
tofu init

# Deploy infrastructure
tofu plan -var-file="openstudio-small.tfvars" -out=tfplan
tofu apply tfplan
```

### 2. Kubernetes Deployment

```bash
# Generate inventory (automatically detects Terraform outputs)
# Copy custom group_vars
cp -r kubespray/inventory/sample/group_vars inventory/

# Run Kubespray
cd $HOME/kubespray
ansible-playbook -i ../openstudio-server-helm/openstack/inventory/inventory.ini \
  --become --become-user=root cluster.yml
```

### 3. Configure Storage and Services

```bash
# Get kubeconfig
scp ubuntu@<master-ip>:/etc/kubernetes/admin.conf ./kubeconfig
export KUBECONFIG=$(pwd)/kubeconfig

# Apply storage classes
kubectl apply -f storage-classes.yaml

# Optional: create a local override values file from tracked template
cp ./openstudio-server/values_production.templateyaml ./openstudio-server/values.local.yaml

# Recommended default for this environment:
#   secrets.existingSecret: openstudio-app-secrets
#   secrets.create: false
# (set these in your local values file, e.g. values.local.yaml)

# Option A (recommended): create one Kubernetes Secret and reference it
kubectl -n openstudio-server create secret generic openstudio-app-secrets \
  --from-literal=db-username="openstudio" \
  --from-literal=db-password="replace-with-strong-password" \
  --from-literal=redis-password="replace-with-strong-password" \
  --from-literal=web-secret-key="replace-with-long-random-secret"

# Option B: let chart create Secret from values at deploy time
export OS_DB_USERNAME="openstudio"
export OS_DB_PASSWORD="replace-with-strong-password"
export OS_REDIS_PASSWORD="replace-with-strong-password"
export OS_SECRET_KEY_BASE="replace-with-long-random-secret"

# Deploy OpenStudio Server
helm upgrade --install openstudio-server ./openstudio-server \
  --namespace openstudio-server \
  --create-namespace \
  -f ./openstudio-server/values.yaml \
  -f ./openstudio-server/values.local.yaml \
  --timeout=20m \
  --wait
```

Preflight checks for Option A (existing secret):

```bash
kubectl get secret -n openstudio-server openstudio-app-secrets
kubectl get secret -n openstudio-server openstudio-app-secrets -o jsonpath='{.data}' | jq 'keys'
./scripts/validate-app-secret.sh --namespace openstudio-server --secret-name openstudio-app-secrets
```

Expected keys:

- `db-username`
- `db-password`
- `redis-password`
- `web-secret-key`

Security hardening notes:

- The chart no longer ships plaintext default credentials.
- App pods use `secretKeyRef` for DB/Redis/app secrets.
- If using chart-managed secrets (`secrets.create=true`), deploys fail fast unless `db.username`, `db.password`, `redis.password`, and `web.secret_key_value` are set.
- If using an externally managed secret (`secrets.existingSecret`), credentials only need to be entered once when creating that secret.
- `secrets.validateExistingSecret` is strict by default. For offline render-only checks, set `--set secrets.validateExistingSecret=false`.
- For normal upgrades in this environment, keep shared defaults in tracked `./openstudio-server/values.yaml` and put local overrides in `./openstudio-server/values.local.yaml`.
- If your cluster policy blocks Helm hook jobs, disable cleanup hook with `--set hooks.preDeleteCleanup.enabled=false`.
- If `secrets.existingSecret` is set, keep `secrets.create=false`; the chart now fails fast when both are enabled.
- `provider.name` is deprecated and disabled by default; use `global.provider.name`. For temporary migration-only fallback, set `global.provider.allowLegacyName=true`.

### Upgrade migration for `--reuse-values` users

Older installs that relied on chart-managed or plaintext values should migrate to an external Kubernetes Secret before upgrading:

```bash
# 1) Create (or update) the app secret in the release namespace
kubectl -n openstudio-server create secret generic openstudio-app-secrets \
  --from-literal=db-username="openstudio" \
  --from-literal=db-password="replace-with-strong-password" \
  --from-literal=redis-password="replace-with-strong-password" \
  --from-literal=web-secret-key="replace-with-long-random-secret" \
  --dry-run=client -o yaml | kubectl apply -f -

# 2) Ensure your local values file uses external-secret mode
# secrets:
#   existingSecret: openstudio-app-secrets
#   create: false

# 3) Upgrade using explicit values file (preferred over pure --reuse-values)
helm upgrade --install openstudio-server ./openstudio-server \
  --namespace openstudio-server \
  -f ./openstudio-server/values.yaml
```

By default, this chart enables Cluster Autoscaler on AWS and disables it for other providers (including OpenStack). If you want autoscaling on OpenStack, set:

- `autoscaler.enabled: true`
- `autoscaler.openstackNodeGroups` entries with `name`, `min`, and `max`
- `autoscaler.expander` (optional) when selecting a non-default node-group expander strategy
- either `autoscaler.openstack.cloudConfigSecretName` **or** a `--cloud-config=...` arg in `autoscaler.extraArgs`
- optional private-CA wiring via `autoscaler.openstack.caBundleSecretName` (with optional `caBundleSecretKey` and `caBundleMountPath`)

`autoscaler.image.tag` defaults to `v<cluster-major>.<cluster-minor>.0` and is validated against cluster version to reduce Kubernetes/cluster-autoscaler version skew.

When `autoscaler.enabled=true` on OpenStack, the chart performs a safety check and fails install/upgrade if a pre-existing `kube-system/cluster-autoscaler` deployment exists and is not owned by this Helm release. This prevents dual autoscaler configuration drift with platform-managed clusters (for example Azimuth).

If your release-time RBAC cannot read `kube-system` deployments, set:

```yaml
autoscaler:
  openstack:
    checkExistingDeploymentOwnership: false
```

Use this override only when required by RBAC constraints.

Example:

```yaml
autoscaler:
  enabled: true
  expander: priority
  openstack:
    cloudConfigSecretName: cloud-config
    # Optional for private OpenStack API CAs:
    caBundleSecretName: openstack-api-ca
    # caBundleSecretKey: ca.crt
    # caBundleMountPath: /etc/ssl/certs/openstack-ca.crt
  openstackNodeGroups:
    - name: web-group
      min: 1
      max: 5
    - name: worker-group
      min: 1
      max: 50
  # Optional: deterministic node-group ordering for expander=priority
  # priorityExpander:
  #   enabled: true
  #   config: |
  #     50:
  #       - .*worker-on-demand.*
  #     10:
  #       - .*worker-spot.*
```

When `caBundleSecretName` is set, the chart mounts the CA file and sets `SSL_CERT_FILE` in the autoscaler container. If you already bake private CA trust into node/runtime images, this is not required.

The chart now reads provider from `global.provider.name` in your values file and applies provider-aware node affinity defaults automatically. For OpenStack, the default node label assumptions are:

- Label key: `capi.stackhpc.com/node-group`
- Web node group value: `web`
- Worker node group value: `worker`

OpenStack defaults to `global.nodeGroups.affinityMode: preferred` to avoid unschedulable pods when labels drift; set `required` to enforce strict placement.
You can also override per role with `global.nodeGroups.webAffinityMode` and `global.nodeGroups.workerAffinityMode` (for example keep web preferred but enforce worker required during burst scaling).

If your cluster uses different labels, set `global.nodeGroups.labelKey`, `global.nodeGroups.web`, and `global.nodeGroups.worker` in your values file.

Additional OpenStack defaults are automatically applied when omitted in values:

- `db.persistence.storageClass`: `nfs`
- `redis.persistence.storageClass`: `nfs`
- `load_balancer.externalTrafficPolicy`: `Cluster`

> [!IMPORTANT]
> The OpenStack `nfs` defaults for `db` and `redis` are compatibility defaults, not production-safe defaults.
> In production, explicitly set both to block storage (`csi-cinder` or your `global.storageClasses.block` class).
> Keep `nfs` for shared artifacts (`nfs_pvc`) only.

For OpenStack block-backed PVCs, the chart now uses `global.storageClasses.block` (default `csi-cinder`) as the backing class for the NFS provisioner PVC.
`openstack/storage-classes.yaml` also includes a `csi-cinder` compatibility alias for older clusters/configs.

For production hardening, the tracked `openstudio-server/values_production.templateyaml` explicitly sets:

- `db.persistence.storageClass: csi-cinder`
- `redis.persistence.storageClass: csi-cinder`
- `nfs-server-provisioner.persistence.size: 1Ti`

Incident retrospective (June 2026):

- Observed failure mode: analyses failed before simulation start with MongoDB WiredTiger `Operation not permitted` errors.
- Root cause: DB PVC was configured to NFS.
- Operational policy now: DB/Redis must stay on block storage; NFS is for shared simulation artifacts only.

Rollout warning triage (OpenStack):

- `UpdateLoadBalancerFailed` / `SyncLoadBalancerFailed` events can occur transiently during node/pool membership updates.
- Treat these as **warning noise** if all are true:
  - `kubectl get svc -n openstudio-server ingress-load-balancer` shows an external IP,
  - `/` and `/status.json` return HTTP 200,
  - web/worker deployments are fully available.
- Escalate when warnings persist and service health fails (missing external IP, non-200 health checks, or unavailable web deployment).
- If kubectl/Helm frequently fail with `502 Bad Gateway` from an nginx proxy, this is a control-plane/API gateway incident; stabilize API path first before further app rollouts.
- If CCM/Service events contain a provider fault like `vs-api.hpc.nrel.gov ... got 500` and an internal `faultstring` referencing an unreachable endpoint (`vs-api.hpc.nlr.gov`), this is an OpenStack control-plane endpoint/DNS misconfiguration, not a Helm chart issue.

Pod termination caveats:

- `FailedKillPod` events during rollout usually indicate node/container-runtime cleanup delays for replaced pods.
- If replacement pods are healthy and workloads continue, this is typically infra-side and not a chart-level app failure.
- Track affected node(s) and coordinate runtime remediation (containerd/kubelet health, node pressure, host IO saturation).

NFS rollout safety:

- `nfs-server-provisioner` is single-replica with an RWO backend PVC.
- Keep deployment strategy at `Recreate` to avoid simultaneous old/new pods competing for `nfs-pvc-data` during upgrades.

Mongo host tuning note:

- Mongo startup may warn `vm.max_map_count is too low`. This is host-level kernel tuning and should be remediated on worker nodes hosting Mongo.

Preflight check before deploy/upgrade:

```bash
kubectl get storageclass
kubectl get sc csi-cinder
kubectl get pvc -n openstudio-server
kubectl get pv | grep -E "openstudio-server/(db|redis|nfs-pvc|nfs-pvc-data)"
```

If your cluster uses a different Cinder class name, set it explicitly in your values file:

```yaml
global:
  storageClasses:
    block: <your-cinder-storageclass-name>
```

Render/lint matrix before deploy:

```bash
./scripts/install-dry-run.sh
```

Kubeconfig helper scripts now default to TLS verification with `tls-server-name=kubernetes`.
If your API server certificate uses a different server name, set:

```bash
KUBE_TLS_SERVER_NAME=<server-name-in-cert> ./setup-kubectl.sh
```

Only if required, you can opt into insecure mode:

```bash
OPENSTACK_ALLOW_INSECURE_KUBECTL=true ./setup-kubectl.sh
```

## 🖥️ Required OpenStack Flavors

This section documents the VM flavors required to run OpenStudio Server optimally.
Request flavors that do not yet exist from your OpenStack admin.

### Flavor Analysis

The cluster runs up to **7,900 worker pods** (HPA max), each requesting **600m CPU / 700 Mi RAM**.
Overhead (daemonset/system) pods run on every node regardless of size. Larger nodes =
fewer nodes = lower overhead pod percentage.

| Flavor size | Pods/node | Nodes @ max | Overhead pods | Overhead % |
|---|---|---|---|---|
| 32 vCPU / 300 Gi (old `CE.XLarge`) | 48 | 165 | ~1,975 | **20%** |
| 64 vCPU / 256 Gi | 96 | 82 | ~990 | 11% |
| 96 vCPU / 256 Gi | 144 | 55 | ~660 | 8% |
| **192 vCPU / 256 Gi** (`CM.192Core.256G`) | **250** | **32** | **~384** | **4.6%** |

`kubelet_max_pods: 250` is already set in `kubespray/inventory/sample/group_vars/all.yml`, making
250 pods/node the binding cap regardless of core count. This aligns perfectly with 192-vCPU nodes.

### Worker Nodes — `CM.192Core.256G` *(must be requested from admin)*

```
Name:    CM.192Core.256G   (or preferred naming convention)
vCPUs:   192              (1:1 mapping to 192-core physical hosts — no NUMA crossover)
RAM:     256 GB           (minimum; 512 GB preferred if physically available)
Disk:    0 GB             (nodes use Cinder boot volumes via Terraform)
```

**Why 192 vCPUs?**
- Matches physical core count 1:1; avoids cross-NUMA vCPU mapping overhead
- 250 pods × 700 Mi = 175 Gi RAM consumed; 256 Gi = 69% utilization (healthy)
- Reduces overhead pod rate from 20% → 4.6% — a **4.3× improvement**
- Drops node count at max scale from ~165 → ~32 nodes

**Request command for OpenStack admin:**
```bash
openstack flavor create CM.192Core.256G \
  --vcpus 192 \
  --ram 262144 \
  --disk 0 \
  --description "Compute worker: 192 vCPUs 256GB RAM for OpenStudio simulation pods"
```

### Web Nodes — `CS.2XMedium` *(existing)*

```
Name:    CS.2XMedium   (existing flavor)
vCPUs:   32
RAM:     128 GB
```

Web node workload profile: web (6 CPU / 50 Gi) + MongoDB (4 CPU / 22 Gi) +
Redis (3 CPU / 4 Gi) + web-background ×2 (4 CPU / 8 Gi) + rserve (2 CPU / 4 Gi)
= **19 vCPUs / 88 Gi total**. `CS.2XMedium` (32 vCPU / 128 Gi) provides adequate headroom.

### Master / Control Plane — `CS.2XMedium` *(existing)*

No change from current default. Control-plane workloads are not worker-pod-dense
and do not benefit from 192-vCPU sizing.



### Network Architecture

```
                    ┌─────────────────┐
                    │   External      │
                    │   Network       │
                    │  (Floating IPs) │
                    └─────────────────┘
                            │
                    ┌─────────────────┐
                    │   OpenStack     │
                    │    Router       │
                    └─────────────────┘
                            │
            ┌───────────────┼───────────────┐
            │               │               │
    ┌───────────────┐ ┌──────────────┐ ┌──────────────┐
    │  Master Node  │ │  Web Nodes   │ │ Worker Nodes │
    │   (Control    │ │ (Web UI/API) │ │ (Simulation) │
    │    Plane)     │ │              │ │              │
    └───────────────┘ └──────────────┘ └──────────────┘
```

### Storage Architecture

- **Cinder CSI**: Dynamic persistent volume provisioning
- **SSD Storage Class**: Default for databases and critical data
- **NFS Storage Class**: Shared storage for multi-pod applications
- **Standard Storage Class**: Cost-effective storage for logs/temp data

### Node Workload Separation

- **Web Nodes**: Handle HTTP requests, API calls, and user interface
- **Worker Nodes**: Execute compute-intensive OpenStudio simulations
- **Master Node**: Kubernetes control plane (can be made highly available)

## 🔐 Corporate Firewall Support

The deployment automatically detects and handles corporate firewall restrictions:

### Automatic Detection

- Tests connectivity to major container registries
- Detects certificate interception (common in corporate environments)
- Creates firewall status file: `/etc/corporate-firewall-status`

### Automatic Workarounds

- **Containerd Configuration**: Selective TLS verification bypassing
- **Download Settings**: Extended timeouts and retry mechanisms
- **Registry Mirrors**: Fallback registry configurations
- **CNI Configuration**: Pre-configured bridge CNI for reliability

### Manual Override

```bash
# Check firewall detection on nodes
kubectl get nodes -o wide
ssh ubuntu@<node-ip> "cat /etc/corporate-firewall-status"

# View applied workarounds
ssh ubuntu@<node-ip> "cat /etc/containerd/config.toml"
```

## 📊 Monitoring and Troubleshooting

### Check Deployment Status

```bash
# Export kubeconfig
export KUBECONFIG=$(pwd)/kubeconfig

# Check cluster health
kubectl get nodes
kubectl get pods --all-namespaces

# Check OpenStudio Server status
kubectl get pods -n openstudio-server
kubectl get services -n openstudio-server
```

### Access OpenStudio Server

```bash
# Port forward to access web interface
kubectl port-forward -n openstudio-server service/web 8080:80

# Visit: http://localhost:8080
```

### Common Issues

#### Corporate Firewall Issues

```bash
# Check firewall detection logs
ssh ubuntu@<master-ip> "sudo journalctl -u corporate-firewall-detection"

# Check containerd configuration
ssh ubuntu@<master-ip> "sudo cat /etc/containerd/config.toml"
```

#### Storage Issues

```bash
# Check storage classes
kubectl get storageclasses

# Check persistent volumes
kubectl get pv
kubectl get pvc -n openstudio-server
```

#### LoadBalancer Issues

```bash
# Check cloud provider configuration
kubectl get configmap -n kube-system cloud-config -o yaml

# Check external cloud provider
kubectl get pods -n kube-system | grep cloud
```

#### Image Pull BackOff with Low Effective Worker Count

If desired worker replicas are much higher than running replicas, first confirm whether pulls are failing through a mirror/auth path.

```bash
kubectl -n openstudio-server get deploy worker -o wide
kubectl -n openstudio-server get pods -l app=worker --no-headers | awk '{print $3}' | sort | uniq -c
kubectl -n openstudio-server get events --sort-by=.lastTimestamp | tail -n 120
```

High-signal indicator: repeated `Failed to pull image` with `401 UNAUTHORIZED` against a mirrored registry path.

Temporary mitigation for incident response:

1. Ensure workloads use known-cached images.
2. Set `imagePullPolicy: IfNotPresent` for affected containers/init containers.
3. Restart only affected deployments and verify status transitions to `Running`.

Permanent fix is registry/mirror auth correction at the platform/runtime layer.

For large analysis batches, enable the chart prepull DaemonSet temporarily and keep worker autoscaling on `keda-hybrid` with a higher `worker_hpa.minReplicas` floor so queue drain starts immediately once the warm nodes are ready.

#### Node Access (Bastion/Floating IP) Troubles

If direct SSH to node IPs fails, verify the OpenStack network path before troubleshooting Kubernetes:

```bash
openstack network list --external -f table -c ID -c Name
openstack server show <jump-or-bastion-server> -f value -c addresses -c key_name
route -n get <floating-ip>
```

Common causes are unreachable external network selection, missing/incorrect keypair, or no route from current client network.

## 🔄 Updates and Maintenance

### Scaling Workers

```bash
# Scale worker replicas
kubectl scale deployment worker -n openstudio-server --replicas=5

# Add more worker nodes (modify tfvars and re-apply)
# Edit openstudio-small.tfvars: worker_count = 3
tofu plan -var-file="openstudio-small.tfvars"
tofu apply
```

### Upgrading Kubernetes

```bash
# Update Kubespray version in group_vars
# Re-run Kubespray upgrade playbook
cd $HOME/kubespray
ansible-playbook -i ../openstudio-server-helm/openstack/inventory/inventory.ini \
  --become --become-user=root upgrade-cluster.yml
```

## 🧹 Cleanup

```bash
# Destroy entire cluster
./deploy-openstudio-cluster.sh small --cleanup

# Or manually with Terraform
tofu destroy -var-file="openstudio-small.tfvars" -auto-approve
```

## 🤝 Contributing

This solution bridges the gap between AWS EKS and OpenStack deployments, providing:

- Consistent deployment patterns
- Corporate environment compatibility
- Production-ready configurations
- Comprehensive automation

## 📚 Additional Resources

- [OpenStudio Server Documentation](https://github.com/NREL/OpenStudio-server)
- [Kubespray Documentation](https://github.com/kubernetes-sigs/kubespray)
- [OpenStack Cloud Provider](https://github.com/kubernetes/cloud-provider-openstack)
- [OpenTofu Documentation](https://opentofu.org/docs/)
