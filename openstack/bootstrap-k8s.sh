#!/bin/bash

# bootstrap-k8s.sh
# Post-deployment Kubernetes bootstrap script
#
# This script:
# 1. Monitors the Kubernetes cluster initialization progress
# 2. Waits for all nodes to be ready
# 3. Configures kubectl for local access
# 4. Sets up NFS storage with external provisioner
# 5. Verifies cluster readiness for OpenStudio Server

set -e

KUBE_TLS_SERVER_NAME="${KUBE_TLS_SERVER_NAME:-kubernetes}"
OPENSTACK_ALLOW_INSECURE_KUBECTL="${OPENSTACK_ALLOW_INSECURE_KUBECTL:-false}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_progress() {
    echo -e "${PURPLE}[PROGRESS]${NC} $1"
}

configure_kubectl_tls() {
    if [[ "${OPENSTACK_ALLOW_INSECURE_KUBECTL}" == "true" ]]; then
        kubectl config set-cluster kubernetes --insecure-skip-tls-verify=true >/dev/null
        print_warning "TLS verification disabled (OPENSTACK_ALLOW_INSECURE_KUBECTL=true)"
        return
    fi

    kubectl config set-cluster kubernetes --insecure-skip-tls-verify=false >/dev/null
    kubectl config set-cluster kubernetes --tls-server-name="${KUBE_TLS_SERVER_NAME}" >/dev/null
    print_status "TLS verification enabled (tls-server-name=${KUBE_TLS_SERVER_NAME})"
}

# Ensure default StorageClass is set to the desired class (defaults to nfs-client)
ensure_default_storageclass() {
    local desired="${1:-nfs-client}"

    if ! kubectl get storageclass "$desired" >/dev/null 2>&1; then
        print_error "StorageClass '$desired' not found"
        kubectl get storageclass || true
        return 1
    fi

    local current
    current=$(kubectl get storageclass -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}')
    if [[ "$current" != "$desired" ]]; then
        print_status "Setting default StorageClass to '$desired'"
        for sc in $(kubectl get storageclass -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); do
            if [[ "$sc" == "$desired" ]]; then
                kubectl annotate storageclass "$sc" storageclass.kubernetes.io/is-default-class="true" --overwrite >/dev/null 2>&1 || true
            else
                kubectl annotate storageclass "$sc" storageclass.kubernetes.io/is-default-class="false" --overwrite >/dev/null 2>&1 || true
            fi
        done
    fi

    kubectl get storageclass
    print_success "Default StorageClass ensured: $desired"
}

# Label nodes into web and worker groups; optionally taint worker nodes when WORKER_TAINT=true
label_and_taint_nodegroups() {
    print_status "Labeling nodes into web and worker groups"

    for n in $(kubectl get nodes -o name); do
        local name="${n#node/}"
        if [[ "$name" == *"web"* ]]; then
            kubectl label "$n" nodegroup=web --overwrite >/dev/null 2>&1 || true
        elif [[ "$name" == *"worker"* || "$name" == *"wrk"* || "$name" == *"compute"* ]]; then
            kubectl label "$n" nodegroup=worker --overwrite >/dev/null 2>&1 || true
        fi
    done

    if [[ "${WORKER_TAINT:=false}" == "true" ]]; then
        print_status "Applying optional worker taint 'worker=true:NoSchedule'"
        for n in $(kubectl get nodes -l nodegroup=worker -o name); do
            kubectl taint "$n" worker=true:NoSchedule --overwrite >/dev/null 2>&1 || true
        done
    fi

    kubectl get nodes --show-labels | grep -E "nodegroup=(web|worker)" || true
    print_success "Node labeling complete"
}

# Ensure OpenStack cloud-config Secret exists in kube-system for CCM (Octavia)
ensure_openstack_cloud_secret() {
    print_status "Ensuring OpenStack cloud-config Secret exists in kube-system"

    if kubectl -n kube-system get secret cloud-config >/dev/null 2>&1; then
        print_success "cloud-config Secret already present"
        return 0
    fi

    if [[ -f "openstack-cloud-config.yaml" ]]; then
        kubectl apply -f openstack-cloud-config.yaml >/dev/null 2>&1 || {
            print_error "Failed to apply openstack-cloud-config.yaml"
            return 1
        }
        print_success "Applied openstack-cloud-config.yaml (cloud-config Secret created)"
    else
        print_warning "openstack-cloud-config.yaml not found; CCM may not provision Octavia LoadBalancers"
        return 1
    fi
}

# Check prerequisites
check_prerequisites() {
    print_status "Checking prerequisites..."
    
    if ! command -v tofu &> /dev/null; then
        print_error "OpenTofu (tofu) is not installed or not in PATH"
        exit 1
    fi
    
    if ! command -v kubectl &> /dev/null; then
        print_error "kubectl is not installed or not in PATH"
        exit 1
    fi
    
    if ! command -v ssh &> /dev/null; then
        print_error "ssh is not installed or not in PATH"
        exit 1
    fi
    
    if [[ ! -f "main.tf" ]]; then
        print_error "main.tf not found. Please run this script from the openstack/ directory."
        exit 1
    fi
    
    print_success "Prerequisites check passed"
}

# Get cluster information from Terraform
get_cluster_info() {
    print_status "Retrieving cluster information from Terraform..."
    
    # Use the tofu-with-env.sh script if available
    if [[ -f "./tofu-with-env.sh" ]]; then
        TOFU_CMD="./tofu-with-env.sh"
    else
        TOFU_CMD="tofu"
        print_warning "tofu-with-env.sh not found, using tofu directly"
    fi
    
    # Get cluster endpoints
    MASTER_FLOATING_IP=$(${TOFU_CMD} output -raw master_floating_ip 2>/dev/null | tail -n 1)
    MASTER_PRIVATE_IP=$(${TOFU_CMD} output -raw master_ip 2>/dev/null | tail -n 1)
    
    if [[ -z "$MASTER_FLOATING_IP" ]]; then
        print_error "Could not retrieve master_floating_ip from Terraform output"
        exit 1
    fi
    
    if [[ -z "$MASTER_PRIVATE_IP" ]]; then
        print_error "Could not retrieve master_ip from Terraform output"
        exit 1
    fi
    
    print_success "Master floating IP: $MASTER_FLOATING_IP"
    print_success "Master private IP: $MASTER_PRIVATE_IP"
}

# Monitor cluster initialization
monitor_cluster_init() {
    print_status "Monitoring Kubernetes cluster initialization..."
    print_status "This may take 10-15 minutes for the complete process..."
    
    local max_attempts=15  # 60 minutes max
    local attempt=1
    
    while [[ $attempt -le $max_attempts ]]; do
        print_progress "Attempt $attempt/$max_attempts: Checking cluster status..."
        
        # Check if we can SSH to master
        if ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no ubuntu@$MASTER_FLOATING_IP "echo 'SSH connection successful'" &>/dev/null; then
            print_success "SSH connection to master node established"
            
            # Check if master initialization is complete
            if ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no ubuntu@$MASTER_FLOATING_IP "test -f /opt/master-initialized" &>/dev/null; then
                print_success "Master node initialization complete"
                
                # Check if all nodes are ready
                local nodes_ready=$(ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no ubuntu@$MASTER_FLOATING_IP "kubectl get nodes --no-headers 2>/dev/null | wc -l" 2>/dev/null || echo "0")
                local nodes_not_ready=$(ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no ubuntu@$MASTER_FLOATING_IP "kubectl get nodes --no-headers 2>/dev/null | grep -v Ready | wc -l" 2>/dev/null || echo "1")
                
                if [[ "$nodes_ready" -ge 3 && "$nodes_not_ready" -eq 0 ]]; then
                    print_success "All nodes are Ready!"
                    return 0
                else
                    print_progress "Nodes status: $nodes_ready total, $nodes_not_ready not ready"
                fi
            else
                print_progress "Master node still initializing..."
            fi
        else
            print_progress "Waiting for master node to become accessible..."
        fi
        
        sleep 30
        ((attempt++))
    done
    
    print_error "Cluster initialization timed out after $max_attempts attempts"
    print_error "Check the cloud-init logs on the instances:"
    print_error "  ssh ubuntu@$MASTER_FLOATING_IP 'sudo tail -f /var/log/cloud-init-output.log'"
    return 1
}

# Copy kubeconfig from master
setup_local_kubectl() {
    print_status "Setting up local kubectl access..."
    
    # Create backup of existing kubeconfig
    if [[ -f "$HOME/.kube/config" ]]; then
        BACKUP_PATH="$HOME/.kube/config.backup.$(date +%Y%m%d-%H%M%S)"
        print_status "Backing up existing kubeconfig to $BACKUP_PATH"
        cp "$HOME/.kube/config" "$BACKUP_PATH"
    fi
    
    # Create .kube directory if it doesn't exist
    mkdir -p "$HOME/.kube"
    
    # Copy kubeconfig from master
    print_status "Copying kubeconfig from master node..."
    scp -o StrictHostKeyChecking=no ubuntu@$MASTER_FLOATING_IP:/home/ubuntu/.kube/config "$HOME/.kube/config.new"
    
    # Update the server endpoint to use floating IP
    sed -i.bak "s|server: https://$MASTER_PRIVATE_IP:6443|server: https://$MASTER_FLOATING_IP:6443|g" "$HOME/.kube/config.new"
    
    # Move the updated config into place
    mv "$HOME/.kube/config.new" "$HOME/.kube/config"
    
    configure_kubectl_tls
    
    print_success "Local kubectl configured successfully"
}

# Test kubectl connectivity
test_kubectl() {
    print_status "Testing kubectl connectivity..."
    
    if kubectl cluster-info &>/dev/null; then
        print_success "kubectl is working!"
        kubectl get nodes
    else
        print_error "kubectl connection failed"
        return 1
    fi
}

# Setup NFS storage for the cluster
setup_nfs_storage() {
    print_status "Setting up NFS storage for the cluster..."
    
    # First, setup NFS server on master node
    print_status "Configuring NFS server on master node..."
    ssh -o StrictHostKeyChecking=no ubuntu@$MASTER_FLOATING_IP '
        sudo apt update && sudo apt install -y nfs-kernel-server
        sudo mkdir -p /srv/nfs/k8s-storage
        sudo chown nobody:nogroup /srv/nfs/k8s-storage
        sudo chmod 777 /srv/nfs/k8s-storage
        echo "/srv/nfs/k8s-storage 10.244.0.0/16(rw,sync,no_subtree_check,no_root_squash)
/srv/nfs/k8s-storage 10.0.1.0/24(rw,sync,no_subtree_check,no_root_squash)" | sudo tee /etc/exports
        sudo systemctl enable nfs-server
        sudo systemctl restart nfs-server
        sudo exportfs -ra
    '
    
    # Check if helm is available
    if ! command -v helm &> /dev/null; then
        print_error "Helm is required for NFS provisioner installation"
        return 1
    fi
    
    print_status "Installing NFS subdir external provisioner..."
    
    # Add the NFS provisioner Helm repository
    helm repo add nfs-subdir-external-provisioner https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner/
    helm repo update
    
    # Install the NFS provisioner with hostNetwork enabled to work around pod networking issues
    helm install nfs-subdir-external-provisioner nfs-subdir-external-provisioner/nfs-subdir-external-provisioner \
        --set nfs.server=$MASTER_PRIVATE_IP \
        --set nfs.path=/srv/nfs/k8s-storage \
        --set storageClass.defaultClass=true \
        --namespace kube-system \
        --wait --timeout=300s
    
    # Patch the deployment to use hostNetwork (required due to pod network isolation in OpenStack)
    print_status "Applying hostNetwork patch for NFS provisioner..."
    kubectl patch deployment nfs-subdir-external-provisioner -n kube-system -p '{"spec":{"template":{"spec":{"hostNetwork":true}}}}'
    
    # Wait for the provisioner to be ready
    kubectl rollout status deployment/nfs-subdir-external-provisioner -n kube-system --timeout=300s
    
    print_success "NFS storage setup complete!"
    print_status "Default storage class 'nfs-client' is now available"
}

# Verify cluster readiness
verify_cluster_readiness() {
    print_status "Verifying cluster readiness for OpenStudio Server..."
    
    # Check nodes
    # Post-bootstrap networking healthcheck and quick remediation
    post_bootstrap_network_healthcheck() {
        print_status "Running post-bootstrap networking healthcheck..."

        # Minimal checks: kube-proxy mode, CoreDNS service IP, NodeLocalDNS, Calico nodes
        kubectl -n kube-system get ds kube-proxy >/dev/null 2>&1 || print_warning "kube-proxy not found"
        kubectl -n kube-system get svc coredns >/dev/null 2>&1 || print_warning "CoreDNS service missing"
        kubectl -n kube-system get ds nodelocaldns >/dev/null 2>&1 || print_warning "NodeLocalDNS not found"
        kubectl -n kube-system get po -l k8s-app=calico-node >/dev/null 2>&1 || print_warning "Calico nodes not found"

        # Deploy a tiny netshoot pod for tests
        kubectl apply -f network-debug-pod.yaml >/dev/null 2>&1 || true
        sleep 5

        # Test DNS resolution from a pod via NodeLocalDNS
        POD=$(kubectl get pod -l app=network-debug -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
        if [[ -n "$POD" ]]; then
            if kubectl exec "$POD" -- nslookup kubernetes.default.svc.cluster.local 169.254.25.10 >/dev/null 2>&1; then
                print_success "DNS resolution via NodeLocalDNS works"
            else
                print_warning "DNS resolution via NodeLocalDNS failed; attempting DNS component restarts"
                kubectl -n kube-system rollout restart deploy/coredns >/dev/null 2>&1 || true
                kubectl -n kube-system rollout restart ds/nodelocaldns >/dev/null 2>&1 || true
                sleep 10
            fi
        fi

        # If calico-kube-controllers cannot reach API, restart it
        if kubectl -n kube-system get deploy calico-kube-controllers >/dev/null 2>&1; then
            READY=$(kubectl -n kube-system get deploy calico-kube-controllers -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo 0)
            if [[ "${READY:-0}" == "0" ]]; then
                print_warning "calico-kube-controllers not available; restarting"
                kubectl -n kube-system delete pod -l k8s-app=calico-kube-controllers >/dev/null 2>&1 || true
            fi
        fi
    }

    local nodes_count=$(kubectl get nodes --no-headers | wc -l)
    if [[ $nodes_count -ge 3 ]]; then
        print_success "Cluster has $nodes_count nodes (minimum 3 required)"
    else
        print_warning "Cluster only has $nodes_count nodes, minimum 3 recommended"
    fi
    
    # Check node labels
    local web_nodes=$(kubectl get nodes -l nodegroup=web --no-headers | wc -l)
    local worker_nodes=$(kubectl get nodes -l nodegroup=worker --no-headers | wc -l)
    
    if [[ $web_nodes -gt 0 ]]; then
        print_success "Found $web_nodes web nodes with proper labels"
    else
        print_warning "No web nodes with nodegroup=web-group labels found"
    fi
    
    if [[ $worker_nodes -gt 0 ]]; then
        print_success "Found $worker_nodes worker nodes with proper labels" 
    else
        print_warning "No worker nodes with nodegroup=worker-group labels found"
    fi
    
    # Check storage classes
    local storage_classes=$(kubectl get storageclass --no-headers | wc -l)
    if [[ $storage_classes -gt 0 ]]; then
        print_success "Found $storage_classes storage class(es)"
        kubectl get storageclass
    else
        print_warning "No storage classes found - you may need to configure Cinder CSI"
    fi
    
    # Check system pods
    local system_pods_ready=$(kubectl get pods -n kube-system --no-headers | grep Running | wc -l)
    local system_pods_total=$(kubectl get pods -n kube-system --no-headers | wc -l)
    
    print_status "System pods: $system_pods_ready/$system_pods_total running"
    
    if [[ $system_pods_ready -eq $system_pods_total ]]; then
        print_success "All system pods are running"
    else
        print_warning "Some system pods are not running yet"
        kubectl get pods -n kube-system | grep -v Running || true
    fi
}

# Main execution
main() {
    echo "=================================="
    echo "Kubernetes Bootstrap Script"
    echo "=================================="
    echo
    
    check_prerequisites
    get_cluster_info
    
    echo
    print_status "Starting cluster initialization monitoring..."
    
    if monitor_cluster_init; then
        echo
        print_success "Cluster initialization complete!"
        
        setup_local_kubectl
        test_kubectl

        # Ensure CCM has cloud-config secret (required for Octavia LB)
        ensure_openstack_cloud_secret || true
        
        echo
        setup_nfs_storage

        ensure_default_storageclass "nfs-client"
        label_and_taint_nodegroups
        
    echo  
        verify_cluster_readiness

    # Networking healthcheck (best-effort)
    echo
    post_bootstrap_network_healthcheck || true
        
        echo
        echo "=================================="
        print_success "Kubernetes cluster is ready!"
        echo "=================================="
        echo
        print_status "Next steps:"
        echo "1. Install OpenStudio Server Helm chart with NFS storage:"
        echo "   helm install openstudio-server ../openstudio-server -f values-openstack-nfs.yaml -n openstudio-test --create-namespace"
        echo "2. Verify NFS storage is working by checking PVCs"
        echo
        print_status "Useful commands:"
        echo "  kubectl get nodes"
        echo "  kubectl get pods --all-namespaces"
        echo "  kubectl get storageclass"
        echo
    else
        echo
        print_error "Cluster initialization failed!"
        echo
        print_status "Troubleshooting steps:"
        echo "1. Check cloud-init logs: ssh ubuntu@$MASTER_FLOATING_IP 'sudo tail -f /var/log/cloud-init-output.log'"
        echo "2. Check master init logs: ssh ubuntu@$MASTER_FLOATING_IP 'sudo tail -f /var/log/master-init.log'"
        echo "3. Check worker join logs on worker nodes"
        echo
        exit 1
    fi
}

# Run main function
main "$@"
