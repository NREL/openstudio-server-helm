#!/bin/bash

##############################################################################
# OpenStudio Server Kubernetes Deployment Automation
##############################################################################

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
DEPLOYMENT_NAME="openstudio-server"
LOG_FILE="deployment-$(date +%Y%m%d-%H%M%S).log"
MAX_RETRIES=5
RETRY_DELAY=30

# Logging function
log() {
    echo -e "${1}" | tee -a "${LOG_FILE}"
}

error() {
    log "${RED}[ERROR]${NC} $1"
    exit 1
}

warning() {
    log "${YELLOW}[WARNING]${NC} $1"
}

success() {
    log "${GREEN}[SUCCESS]${NC} $1"
}

info() {
    log "${BLUE}[INFO]${NC} $1"
}

# Function to check prerequisites
check_prerequisites() {
    info "Checking prerequisites..."
    
    # Check if required commands exist
    local commands=("tofu" "openstack" "ssh" "kubectl")
    for cmd in "${commands[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            error "Required command not found: $cmd"
        fi
    done
    
    # Check if we can authenticate with OpenStack
    if ! openstack token issue &> /dev/null; then
        error "OpenStack authentication failed. Please check your credentials."
    fi
    
    # Check if Terraform configuration exists
    if [[ ! -f "main.tf" ]]; then
        error "Terraform configuration (main.tf) not found in current directory"
    fi
    
    success "Prerequisites check passed"
}

# Function to deploy infrastructure
deploy_infrastructure() {
    info "Deploying OpenStack infrastructure with Terraform..."
    
    # Initialize Terraform if needed
    if [[ ! -d ".terraform" ]]; then
        info "Initializing Terraform..."
        tofu init
    fi
    
    # Plan deployment
    info "Creating Terraform plan..."
    tofu plan -out=deployment.tfplan
    
    # Apply deployment
    info "Applying Terraform configuration..."
    tofu apply -auto-approve deployment.tfplan
    
    # Clean up plan file
    rm -f deployment.tfplan
    
    success "Infrastructure deployment completed"
}

# Function to extract deployment information
get_deployment_info() {
    info "Extracting deployment information..."
    
    # Get master floating IP
    MASTER_IP=$(tofu output -raw master_floating_ip 2>/dev/null || echo "")
    if [[ -z "$MASTER_IP" ]]; then
        error "Could not retrieve master floating IP from Terraform output"
    fi
    
    # Get cluster info
    CLUSTER_NAME=$(tofu output -json cluster_info | jq -r '.cluster_name' 2>/dev/null || echo "openstudio-server")
    TOTAL_NODES=$(tofu output -json cluster_info | jq -r '.total_nodes' 2>/dev/null || echo "3")
    
    info "Master IP: $MASTER_IP"
    info "Cluster Name: $CLUSTER_NAME"
    info "Total Nodes: $TOTAL_NODES"
}

# Function to test connectivity
test_connectivity() {
    info "Testing network connectivity to deployed instances..."
    
    # Test ping first
    if ping -c 3 -W 5 "$MASTER_IP" &> /dev/null; then
        success "Ping test to master node successful"
        return 0
    else
        warning "Ping test to master node failed"
    fi
    
    # Test SSH connectivity
    local retry_count=0
    while [[ $retry_count -lt $MAX_RETRIES ]]; do
        info "Testing SSH connectivity (attempt $((retry_count + 1))/$MAX_RETRIES)..."
        
        if timeout 15 ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no ubuntu@"$MASTER_IP" 'echo "SSH connection successful"' &> /dev/null; then
            success "SSH connectivity test successful"
            return 0
        fi
        
        warning "SSH connectivity test failed, retrying in $RETRY_DELAY seconds..."
        sleep $RETRY_DELAY
        ((retry_count++))
    done
    
    error "SSH connectivity test failed after $MAX_RETRIES attempts"
}

# Function to monitor Kubernetes bootstrap
monitor_kubernetes_bootstrap() {
    info "Monitoring Kubernetes cluster bootstrap process..."
    info "This may take 10-15 minutes for the complete process..."
    
    local retry_count=0
    local max_bootstrap_retries=30
    local bootstrap_delay=30
    
    while [[ $retry_count -lt $max_bootstrap_retries ]]; do
        info "Bootstrap check (attempt $((retry_count + 1))/$max_bootstrap_retries)..."
        
        # Check if cluster is accessible and nodes are ready
        if ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no ubuntu@"$MASTER_IP" 'sudo kubectl get nodes --no-headers 2>/dev/null | wc -l' &> /dev/null; then
            local ready_nodes=$(ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no ubuntu@"$MASTER_IP" 'sudo kubectl get nodes --no-headers 2>/dev/null | grep -c "Ready" || echo "0"')
            
            info "Ready nodes: $ready_nodes/$TOTAL_NODES"
            
            if [[ "$ready_nodes" == "$TOTAL_NODES" ]]; then
                success "All nodes are ready!"
                return 0
            fi
        fi
        
        info "Cluster not ready yet, waiting $bootstrap_delay seconds..."
        sleep $bootstrap_delay
        ((retry_count++))
    done
    
    warning "Kubernetes bootstrap monitoring timed out. Cluster may still be initializing."
    return 1
}

# Function to setup kubectl locally
setup_kubectl() {
    info "Setting up kubectl configuration locally..."
    
    # Create kubeconfig directory if it doesn't exist
    mkdir -p ~/.kube
    
    # Copy kubeconfig from master node
    if scp -o StrictHostKeyChecking=no ubuntu@"$MASTER_IP":/etc/kubernetes/admin.conf ~/.kube/config-"$CLUSTER_NAME" &> /dev/null; then
        
        # Update kubeconfig to use floating IP
        sed -i.bak "s/https:\/\/[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}:6443/https:\/\/$MASTER_IP:6443/g" ~/.kube/config-"$CLUSTER_NAME"
        
        # Merge with existing kubeconfig or set as default
        if [[ -f ~/.kube/config ]]; then
            info "Merging with existing kubeconfig..."
            KUBECONFIG=~/.kube/config:~/.kube/config-"$CLUSTER_NAME" kubectl config view --flatten > ~/.kube/config-merged
            mv ~/.kube/config-merged ~/.kube/config
        else
            cp ~/.kube/config-"$CLUSTER_NAME" ~/.kube/config
        fi
        
        # Set context
        kubectl config use-context kubernetes-admin@kubernetes &> /dev/null || true
        kubectl config set-cluster kubernetes --insecure-skip-tls-verify=true &> /dev/null || true
        
        success "kubectl configuration completed"
        return 0
    else
        warning "Failed to copy kubeconfig from master node"
        return 1
    fi
}

# Function to setup NFS storage
setup_nfs_storage() {
    info "Setting up NFS storage..."
    
    # Check if NFS storage class already exists
    if kubectl get storageclass | grep -q nfs-client; then
        success "NFS storage class is already available"
        return 0
    fi
    
    warning "NFS storage not found, this should be handled by bootstrap script"
    warning "Run: ./bootstrap-k8s.sh to set up NFS storage"
    return 1
}

# Function to verify cluster
verify_cluster() {
    info "Verifying Kubernetes cluster..."
    
    # Test kubectl connectivity
    if ! kubectl cluster-info &> /dev/null; then
        warning "kubectl cluster-info failed"
        return 1
    fi
    
    # Check nodes
    local ready_nodes=$(kubectl get nodes --no-headers | grep -c "Ready" || echo "0")
    if [[ "$ready_nodes" != "$TOTAL_NODES" ]]; then
        warning "Not all nodes are ready ($ready_nodes/$TOTAL_NODES)"
        kubectl get nodes
        return 1
    fi
    
    # Check system pods
    local system_pods_ready=$(kubectl get pods -n kube-system --no-headers | grep -c "Running" || echo "0")
    local total_system_pods=$(kubectl get pods -n kube-system --no-headers | wc -l || echo "0")
    
    info "System pods running: $system_pods_ready/$total_system_pods"
    
    if [[ "$system_pods_ready" -lt 5 ]]; then  # At least 5 system pods should be running
        warning "System pods may not be fully ready"
        kubectl get pods -n kube-system
        return 1
    fi
    
    success "Cluster verification passed"
    return 0
}

# Function to display next steps
show_next_steps() {
    info "==================================="
    info "DEPLOYMENT COMPLETED SUCCESSFULLY!"
    info "==================================="
    echo ""
    info "Cluster Information:"
    info "  Master IP: $MASTER_IP"
    info "  Cluster Name: $CLUSTER_NAME"
    info "  Total Nodes: $TOTAL_NODES"
    echo ""
    info "kubectl is configured and ready to use:"
    info "  kubectl get nodes"
    info "  kubectl get pods --all-namespaces"
    echo ""
    info "To deploy OpenStudio Helm chart:"
    info "  helm upgrade --install openstudio-server ../openstudio-server -f values-openstack-nfs.yaml -n openstudio-test --create-namespace"
    echo ""
    info "SSH Access:"
    info "  ssh ubuntu@$MASTER_IP"
    echo ""
    info "Log file: $LOG_FILE"
}

# Function to handle deployment failure
handle_failure() {
    error "Deployment failed. Check the log file: $LOG_FILE"
    echo ""
    warning "Common troubleshooting steps:"
    warning "1. Check OpenStack authentication: openstack token issue"
    warning "2. Check network connectivity to floating IPs"
    warning "3. Verify security group rules allow SSH (port 22)"
    warning "4. Check DNS resolution within OpenStack network"
    warning "5. Review cloud-init logs: ssh ubuntu@<ip> 'sudo journalctl -u cloud-final'"
    echo ""
    warning "To destroy and retry:"
    warning "  tofu destroy -auto-approve"
    warning "  ./deploy.sh"
}

# Function to show troubleshooting information
show_troubleshooting() {
    warning "==================================="
    warning "TROUBLESHOOTING INFORMATION"
    warning "==================================="
    echo ""
    warning "Current Status:"
    
    # Check if infrastructure exists
    if tofu show &> /dev/null; then
        info "✓ Infrastructure is deployed"
        
        # Get IPs from terraform
        local master_ip=$(tofu output -raw master_floating_ip 2>/dev/null || echo "N/A")
        local web_ips=$(tofu output -json web_floating_ips 2>/dev/null | jq -r '.[]' 2>/dev/null || echo "N/A")
        local worker_ips=$(tofu output -json worker_floating_ips 2>/dev/null | jq -r '.[]' 2>/dev/null || echo "N/A")
        
        echo "  Master IP: $master_ip"
        echo "  Web IPs: $web_ips"
        echo "  Worker IPs: $worker_ips"
        
        # Test connectivity
        if [[ "$master_ip" != "N/A" ]]; then
            if ping -c 1 -W 3 "$master_ip" &> /dev/null; then
                info "✓ Master IP is pingable"
            else
                warning "✗ Master IP is not reachable via ping"
            fi
            
            if timeout 10 ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no ubuntu@"$master_ip" 'echo "SSH OK"' &> /dev/null; then
                info "✓ Master is accessible via SSH"
            else
                warning "✗ Master is not accessible via SSH"
            fi
        fi
    else
        warning "✗ No infrastructure found"
    fi
    
    echo ""
    warning "Common Issues:"
    warning "1. Network connectivity: Some networks block private IP ranges (10.x.x.x)"
    warning "2. DNS resolution: Instances might not reach DNS servers"
    warning "3. Security groups: Firewall rules might block connections"
    warning "4. Cloud-init: Bootstrap scripts might have failed"
    echo ""
    warning "Manual Steps:"
    warning "1. Check OpenStack instances: openstack server list"
    warning "2. Check security groups: openstack security group show openstudio-server-secgroup"
    warning "3. Check router: openstack router show openstudio-server-router"
    warning "4. View console logs: openstack console log show openstudio-server-master"
}

# Main execution function
main() {
    local start_time=$(date +%s)
    
    info "==================================="
    info "OpenStudio Server K8s Deployment"
    info "==================================="
    info "Started at: $(date)"
    info "Log file: $LOG_FILE"
    echo ""
    
    # Handle command line arguments
    case "${1:-deploy}" in
        "deploy")
            # Full deployment workflow
            check_prerequisites
            deploy_infrastructure
            get_deployment_info
            
            if test_connectivity; then
                if monitor_kubernetes_bootstrap; then
                    setup_kubectl
                    setup_nfs_storage
                    
                    if verify_cluster; then
                        show_next_steps
                    else
                        warning "Cluster verification had issues, but deployment may still be usable"
                        show_next_steps
                    fi
                else
                    warning "Bootstrap monitoring timed out, but cluster may still be initializing"
                    warning "You can manually check progress with: ./bootstrap-k8s.sh"
                    show_next_steps
                fi
            else
                handle_failure
            fi
            ;;
        "troubleshoot"|"status")
            show_troubleshooting
            ;;
        "destroy")
            warning "Destroying infrastructure..."
            tofu destroy -auto-approve
            success "Infrastructure destroyed"
            ;;
        "help"|"-h"|"--help")
            echo "Usage: $0 [command]"
            echo ""
            echo "Commands:"
            echo "  deploy        Deploy the complete Kubernetes cluster (default)"
            echo "  troubleshoot  Show troubleshooting information"
            echo "  status        Same as troubleshoot"
            echo "  destroy       Destroy the infrastructure"
            echo "  help          Show this help"
            ;;
        *)
            error "Unknown command: $1. Use '$0 help' for usage information."
            ;;
    esac
    
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    info "Total execution time: ${duration} seconds"
}

# Trap to handle script interruption
trap 'error "Script interrupted by user"' INT TERM

# Execute main function with all arguments
main "$@"
