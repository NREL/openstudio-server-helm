#!/bin/bash
# OpenStudio Server Kubernetes Cluster Deployment Script for OpenStack
# This script automates the full deployment process with corporate firewall support

set -euo pipefail

# Script configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUBESPRAY_PATH="${KUBESPRAY_PATH:-$HOME/kubespray}"
HELM_CHART_PATH="${HELM_CHART_PATH:-../openstudio-server}"
HELM_VALUES_FILE="${HELM_VALUES_FILE:-$SCRIPT_DIR/values-openstack.yaml}"
APP_SECRET_NAME="${APP_SECRET_NAME:-openstudio-app-secrets}"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging function
log() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

# Help function
usage() {
    cat << EOF
Usage: $0 [OPTIONS] <CLUSTER_SIZE>

Deploy OpenStudio Server Kubernetes cluster on OpenStack

CLUSTER_SIZE:
    small   - Deploy small cluster configuration (2 web, 1 worker)
    large   - Deploy large cluster configuration (1 web, 1 worker, high-spec)
    test    - Deploy test cluster (single master only)

OPTIONS:
    -h, --help              Show this help message
    -c, --cleanup           Clean up existing cluster before deployment
    -s, --skip-terraform    Skip Terraform infrastructure deployment
    -k, --skip-kubespray    Skip Kubespray Kubernetes deployment
    -d, --skip-helm         Skip Helm chart deployment
    -v, --verbose           Enable verbose output

ENVIRONMENT VARIABLES:
    Required OpenStack credentials:
    - TF_VAR_openstack_user_name
    - TF_VAR_openstack_password
    - TF_VAR_openstack_auth_url
    - TF_VAR_openstack_tenant_name
    - TF_VAR_openstack_user_domain_name
    - TF_VAR_openstack_project_domain_id
    - TF_VAR_openstack_project_id
    - HELM_VALUES_FILE (optional; default: ./values-openstack.yaml)
    - APP_SECRET_NAME (optional; default: openstudio-app-secrets)

Examples:
    $0 small                    # Deploy small cluster
    $0 large --cleanup          # Clean up and deploy large cluster
    $0 test --skip-helm         # Deploy test cluster without helm

EOF
}

# Parse command line arguments
CLUSTER_SIZE=""
CLEANUP=false
SKIP_TERRAFORM=false
SKIP_KUBESPRAY=false
SKIP_HELM=false
VERBOSE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            usage
            exit 0
            ;;
        -c|--cleanup)
            CLEANUP=true
            shift
            ;;
        -s|--skip-terraform)
            SKIP_TERRAFORM=true
            shift
            ;;
        -k|--skip-kubespray)
            SKIP_KUBESPRAY=true
            shift
            ;;
        -d|--skip-helm)
            SKIP_HELM=true
            shift
            ;;
        -v|--verbose)
            VERBOSE=true
            set -x
            shift
            ;;
        small|large|test)
            CLUSTER_SIZE="$1"
            shift
            ;;
        *)
            error "Unknown option: $1"
            ;;
    esac
done

# Validate cluster size
if [[ -z "$CLUSTER_SIZE" ]]; then
    error "Cluster size is required. Use 'small', 'large', or 'test'"
fi

# Validate cluster size options
case "$CLUSTER_SIZE" in
    small|large|test)
        ;;
    *)
        error "Invalid cluster size: $CLUSTER_SIZE. Use 'small', 'large', or 'test'"
        ;;
esac

# Check prerequisites
check_prerequisites() {
    log "Checking prerequisites..."
    
    # Check required tools
    local tools=("tofu" "ansible" "kubectl" "helm")
    for tool in "${tools[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            error "$tool is not installed or not in PATH"
        fi
    done
    
    # Check OpenStack credentials
    local required_vars=(
        "TF_VAR_openstack_user_name"
        "TF_VAR_openstack_password"
        "TF_VAR_openstack_tenant_name"
    )
    
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            error "Required environment variable $var is not set"
        fi
    done

    local tfvars_file="openstudio-${CLUSTER_SIZE}.tfvars"
    local auth_url="${TF_VAR_openstack_auth_url:-}"
    local auth_url_trimmed="${auth_url//[[:space:]]/}"
    if [[ -z "$auth_url_trimmed" ]]; then
        if [[ ! -f "$tfvars_file" ]] || ! grep -Eq '^[[:space:]]*openstack_auth_url[[:space:]]*=' "$tfvars_file"; then
            error "Set TF_VAR_openstack_auth_url or define openstack_auth_url in $tfvars_file"
        fi
    fi
    
    # Check Kubespray
    if [[ ! -d "$KUBESPRAY_PATH" ]] && [[ "$SKIP_KUBESPRAY" == false ]]; then
        warning "Kubespray not found at $KUBESPRAY_PATH"
        read -p "Do you want to clone Kubespray? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            git clone https://github.com/kubernetes-sigs/kubespray.git "$KUBESPRAY_PATH"
            cd "$KUBESPRAY_PATH"
            pip install -r requirements.txt
            cd "$SCRIPT_DIR"
        else
            error "Kubespray is required for deployment"
        fi
    fi
    
    success "Prerequisites check passed"
}

# Clean up existing infrastructure
cleanup_cluster() {
    if [[ "$CLEANUP" == true ]]; then
        log "Cleaning up existing cluster..."
        
        if [[ -f terraform.tfstate ]]; then
            log "Destroying existing Terraform infrastructure..."
            tofu destroy -var-file="openstudio-${CLUSTER_SIZE}.tfvars" -auto-approve || warning "Terraform destroy had warnings"
        fi
        
        success "Cleanup completed"
    fi
}

# Deploy infrastructure with Terraform
deploy_infrastructure() {
    if [[ "$SKIP_TERRAFORM" == true ]]; then
        log "Skipping Terraform deployment..."
        return
    fi
    
    log "Deploying infrastructure with Terraform..."
    
    local tfvars_file="openstudio-${CLUSTER_SIZE}.tfvars"
    if [[ ! -f "$tfvars_file" ]]; then
        error "Configuration file $tfvars_file not found"
    fi
    
    # Initialize Terraform
    tofu init
    
    # Plan deployment
    log "Planning Terraform deployment..."
    tofu plan -var-file="$tfvars_file" -out=tfplan
    
    # Apply deployment
    log "Applying Terraform deployment..."
    tofu apply tfplan
    
    # Wait for instances to be ready
    log "Waiting for instances to be ready..."
    sleep 60
    
    success "Infrastructure deployment completed"
}

# Generate Kubespray inventory
generate_inventory() {
    log "Generating Kubespray inventory..."
    
    # Get Terraform outputs
    local master_ip
    local web_ips
    local worker_ips
    
    master_ip=$(tofu output -raw master_floating_ip 2>/dev/null || echo "")
    web_ips=$(tofu output -json web_floating_ips 2>/dev/null | jq -r '.[]' || echo "")
    worker_ips=$(tofu output -json worker_floating_ips 2>/dev/null | jq -r '.[]' || echo "")
    
    if [[ -z "$master_ip" ]]; then
        error "Could not get master IP from Terraform output"
    fi
    
    # Create inventory file
    local inventory_file="inventory/inventory.ini"
    mkdir -p inventory
    
    cat > "$inventory_file" << EOF
[all]
master ansible_host=$master_ip ip=$master_ip
EOF
    
    # Add web nodes if they exist
    if [[ -n "$web_ips" ]]; then
        local web_count=1
        while IFS= read -r web_ip; do
            if [[ -n "$web_ip" ]]; then
                echo "web-$web_count ansible_host=$web_ip ip=$web_ip" >> "$inventory_file"
                ((web_count++))
            fi
        done <<< "$web_ips"
    fi
    
    # Add worker nodes if they exist
    if [[ -n "$worker_ips" ]]; then
        local worker_count=1
        while IFS= read -r worker_ip; do
            if [[ -n "$worker_ip" ]]; then
                echo "worker-$worker_count ansible_host=$worker_ip ip=$worker_ip" >> "$inventory_file"
                ((worker_count++))
            fi
        done <<< "$worker_ips"
    fi
    
    # Add group definitions
    cat >> "$inventory_file" << EOF

[kube-master]
master

[etcd]
master

[kube-node]
EOF
    
    # Add web nodes to kube-node group
    if [[ -n "$web_ips" ]]; then
        local web_count=1
        while IFS= read -r web_ip; do
            if [[ -n "$web_ip" ]]; then
                echo "web-$web_count" >> "$inventory_file"
                ((web_count++))
            fi
        done <<< "$web_ips"
    fi
    
    # Add worker nodes to kube-node group
    if [[ -n "$worker_ips" ]]; then
        local worker_count=1
        while IFS= read -r worker_ip; do
            if [[ -n "$worker_ip" ]]; then
                echo "worker-$worker_count" >> "$inventory_file"
                ((worker_count++))
            fi
        done <<< "$worker_ips"
    fi
    
    cat >> "$inventory_file" << EOF

[calico-rr]

[k8s-cluster:children]
kube-master
kube-node
calico-rr

[k8s-cluster:vars]
ansible_user=ubuntu
ansible_ssh_private_key_file=~/.ssh/id_rsa
EOF
    
    success "Inventory generated: $inventory_file"
}

# Deploy Kubernetes with Kubespray
deploy_kubernetes() {
    if [[ "$SKIP_KUBESPRAY" == true ]]; then
        log "Skipping Kubespray deployment..."
        return
    fi
    
    log "Deploying Kubernetes with Kubespray..."
    
    # Copy custom group_vars
    log "Copying custom group_vars..."
    cp -r "$SCRIPT_DIR/kubespray/inventory/sample/group_vars" "$SCRIPT_DIR/inventory/"
    
    # Run Kubespray
    cd "$KUBESPRAY_PATH"
    
    # Detect if we should use corporate firewall wrapper
    local ansible_command="ansible-playbook"
    local master_ip
    master_ip=$(cd "$SCRIPT_DIR" && tofu output -raw master_floating_ip)
    
    # Check if corporate firewall wrapper exists on master node
    if ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no "ubuntu@$master_ip" "test -f /usr/local/bin/kubespray-corporate-firewall.sh" 2>/dev/null; then
        log "Corporate firewall detection found, using wrapper script"
        export CORPORATE_FIREWALL_DETECTED=true
    fi
    
    log "Running Kubespray playbook..."
    $ansible_command -i "$SCRIPT_DIR/inventory/inventory.ini" \
        --become --become-user=root \
        cluster.yml
    
    cd "$SCRIPT_DIR"
    
    success "Kubernetes deployment completed"
}

# Configure cluster post-deployment
configure_cluster() {
    log "Configuring cluster..."
    
    # Get kubeconfig
    local master_ip
    master_ip=$(tofu output -raw master_floating_ip)
    
    log "Retrieving kubeconfig from master node..."
    scp -o StrictHostKeyChecking=no "ubuntu@$master_ip:/etc/kubernetes/admin.conf" "./kubeconfig"
    
    # Update kubeconfig with external IP
    sed -i.bak "s/127.0.0.1:6443/$master_ip:6443/g" "./kubeconfig"
    sed -i.bak "s/localhost:6443/$master_ip:6443/g" "./kubeconfig"
    
    export KUBECONFIG="$SCRIPT_DIR/kubeconfig"
    
    # Wait for cluster to be ready
    log "Waiting for cluster to be ready..."
    local retries=0
    local max_retries=30
    
    while ! kubectl get nodes &>/dev/null && [[ $retries -lt $max_retries ]]; do
        sleep 10
        ((retries++))
        log "Waiting for cluster... (attempt $retries/$max_retries)"
    done
    
    if [[ $retries -eq $max_retries ]]; then
        error "Cluster did not become ready within expected time"
    fi
    
    # Apply storage classes
    log "Applying storage classes..."
    kubectl apply -f storage-classes.yaml
    
    # Label nodes
    log "Applying node labels..."
    kubectl label nodes --overwrite --selector='!node-role.kubernetes.io/control-plane' nodegroup=worker-group workload=compute || warning "Node labeling had issues"
    
    success "Cluster configuration completed"
}

# Deploy OpenStudio Server Helm chart
deploy_openstudio() {
    if [[ "$SKIP_HELM" == true ]]; then
        log "Skipping Helm chart deployment..."
        return
    fi
    
    log "Deploying OpenStudio Server Helm chart..."
    
    export KUBECONFIG="$SCRIPT_DIR/kubeconfig"
    
    # Add required Helm repositories
    log "Adding Helm repositories..."
    helm repo add nfs-server-provisioner https://kubernetes-sigs.github.io/nfs-ganesha-server-and-external-provisioner
    helm repo update

    if [[ ! -f "$HELM_VALUES_FILE" ]]; then
        error "Helm values file not found: $HELM_VALUES_FILE"
    fi
    
    # Create namespace
    kubectl create namespace openstudio-server || true

    local secret_validator="$SCRIPT_DIR/../scripts/validate-app-secret.sh"
    if [[ ! -x "$secret_validator" ]]; then
        error "Missing executable secret validator: $secret_validator"
    fi
    "$secret_validator" --namespace openstudio-server --secret-name "$APP_SECRET_NAME"
    
    # Deploy OpenStudio Server
    log "Installing OpenStudio Server..."
    helm upgrade --install openstudio-server "$HELM_CHART_PATH" \
        --namespace openstudio-server \
        --values "$HELM_CHART_PATH/values.yaml" \
        --values "$HELM_VALUES_FILE" \
        --set secrets.existingSecret="$APP_SECRET_NAME" \
        --set secrets.create=false \
        --set secrets.validateExistingSecret=true \
        --set global.provider.name=openstack \
        --timeout=20m \
        --wait
    
    success "OpenStudio Server deployment completed"
}

# Display deployment summary
show_summary() {
    log "Deployment Summary"
    echo "=================="
    
    local master_ip
    master_ip=$(tofu output -raw master_floating_ip 2>/dev/null || echo "N/A")
    
    echo "Cluster Size: $CLUSTER_SIZE"
    echo "Master Node IP: $master_ip"
    echo "Kubeconfig: $SCRIPT_DIR/kubeconfig"
    
    if [[ "$SKIP_HELM" == false ]]; then
        export KUBECONFIG="$SCRIPT_DIR/kubeconfig"
        echo ""
        echo "OpenStudio Server Services:"
        kubectl get services -n openstudio-server || warning "Could not get services"
        echo ""
        echo "To access the web interface, run:"
        echo "kubectl port-forward -n openstudio-server service/web 8080:80"
        echo "Then visit: http://localhost:8080"
    fi
    
    echo ""
    echo "SSH to master: ssh ubuntu@$master_ip"
    echo "Kubectl access: export KUBECONFIG=$SCRIPT_DIR/kubeconfig"
    
    success "Deployment completed successfully!"
}

# Main deployment flow
main() {
    log "Starting OpenStudio Server deployment ($CLUSTER_SIZE)"
    
    check_prerequisites
    cleanup_cluster
    deploy_infrastructure
    generate_inventory
    deploy_kubernetes
    configure_cluster
    deploy_openstudio
    show_summary
}

# Trap signals for cleanup
trap 'error "Script interrupted"' INT TERM

# Run main function
main "$@"
