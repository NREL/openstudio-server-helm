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
cp ../openstudio-server/values_production.templateyaml ../openstudio-server/values.yaml
# Edit values.yaml (passwords/secrets/resources/provider=openstack)
helm install openstudio-server ../openstudio-server
```

## Legacy Quick Start (Use at Your Own Risk)

If you still need to self-manage Kubernetes on OpenStack with the scripts in this directory:

```bash
./deploy-openstudio-cluster.sh small
```

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

# Deploy OpenStudio Server
helm upgrade --install openstudio-server ../openstudio-server \
  --namespace openstudio-server \
  --create-namespace \
  --set provider.name=openstack \
  --timeout=20m \
  --wait
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
