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
# Edit your values file (resources/provider=openstack/storage classes/secret name)
kubectl -n openstudio-server create secret generic openstudio-app-secrets \
  --from-literal=db-username="openstudio" \
  --from-literal=db-password="replace-with-strong-password" \
  --from-literal=redis-password="replace-with-strong-password" \
  --from-literal=web-secret-key="replace-with-long-random-secret"
helm upgrade --install openstudio-server ../openstudio-server \
  -f ../openstudio-server/values.yaml \
  -f ../openstudio-server/values.local.yaml
```

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
- For normal upgrades in this environment, keep shared defaults in tracked `./openstudio-server/values.yaml` and put local overrides in `./openstudio-server/values.local.yaml`.
- If your cluster policy blocks Helm hook jobs, disable cleanup hook with `--set hooks.preDeleteCleanup.enabled=false`.
- If `secrets.existingSecret` is set, keep `secrets.create=false`; the chart now fails fast when both are enabled.
- `provider.name` is not supported; use `global.provider.name`.

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
- either `autoscaler.openstack.cloudConfigSecretName` **or** a `--cloud-config=...` arg in `autoscaler.extraArgs`

`autoscaler.image.tag` defaults to `v<cluster-major>.<cluster-minor>.0` and is validated against cluster version to reduce Kubernetes/cluster-autoscaler version skew.

When `autoscaler.enabled=true` on OpenStack, the chart performs a safety check and fails install/upgrade if a pre-existing `kube-system/cluster-autoscaler` deployment exists and is not owned by this Helm release. This prevents dual autoscaler configuration drift with platform-managed clusters (for example Azimuth).

Example:

```yaml
autoscaler:
  enabled: true
  openstack:
    cloudConfigSecretName: cloud-config
  openstackNodeGroups:
    - name: web-group
      min: 1
      max: 5
    - name: worker-group
      min: 1
      max: 50
```

The chart now reads provider from `global.provider.name` in your values file and applies provider-aware node affinity defaults automatically. For OpenStack, the default node label assumptions are:

- Label key: `capi.stackhpc.com/node-group`
- Web node group value: `web`
- Worker node group value: `worker`

OpenStack defaults to `global.nodeGroups.affinityMode: preferred` to avoid unschedulable pods when labels drift; set `required` to enforce strict placement.

If your cluster uses different labels, set `global.nodeGroups.labelKey`, `global.nodeGroups.web`, and `global.nodeGroups.worker` in your values file.

Additional OpenStack defaults are automatically applied when omitted in values:

- `db.persistence.storageClass`: `nfs`
- `redis.persistence.storageClass`: `nfs`
- `load_balancer.externalTrafficPolicy`: `Cluster`

For OpenStack block-backed PVCs, the chart now uses `global.storageClasses.block` (default `cinder-csi`) as the backing class for the NFS provisioner PVC.
`openstack/storage-classes.yaml` also includes a `csi-cinder` compatibility alias for older clusters/configs.

For production hardening, the tracked `openstudio-server/values_production.templateyaml` explicitly sets:

- `db.persistence.storageClass: cinder-csi`
- `redis.persistence.storageClass: cinder-csi`
- `nfs-server-provisioner.persistence.size: 1Ti`

Preflight check before deploy/upgrade:

```bash
kubectl get storageclass
kubectl get sc cinder-csi
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

## 🏭 Architecture

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
