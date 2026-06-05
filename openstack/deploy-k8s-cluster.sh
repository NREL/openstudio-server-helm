#!/bin/bash

# deploy-k8s-cluster.sh
# Master orchestration script for automated OpenStack Kubernetes deployment
#
# This script provides a complete one-command deployment:
# 1. Validates prerequisites
# 2. Deploys OpenStack infrastructure with Terraform
# 3. Waits for and monitors automatic Kubernetes bootstrap
# 4. Configures local kubectl access
# 5. Verifies cluster readiness for OpenStudio Server

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

# Function to print colored output
print_header() {
    echo -e "${BOLD}${BLUE}================================================${NC}"
    echo -e "${BOLD}${BLUE}$1${NC}"
    echo -e "${BOLD}${BLUE}================================================${NC}"
}

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

# Function to show usage
show_usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Deploy a complete Kubernetes cluster on OpenStack with automatic bootstrap.

OPTIONS:
  -h, --help        Show this help message
  -d, --destroy     Destroy the existing cluster instead of creating
  -p, --plan-only   Show Terraform plan without applying changes
  -s, --skip-bootstrap  Skip the bootstrap monitoring (deploy infrastructure only)
  --no-kubectl      Skip kubectl configuration setup

EXAMPLES:
  $0                   # Deploy complete cluster with bootstrap
  $0 --plan-only       # Show what would be deployed
  $0 --skip-bootstrap  # Deploy infrastructure only
  $0 --destroy         # Destroy existing cluster

PREREQUISITES:
  - OpenTofu/Terraform installed
  - kubectl installed
  - OpenStack credentials configured in .env file
  - SSH key pair configured

EOF
}

# Parse command line arguments
DESTROY_MODE=false
PLAN_ONLY=false
SKIP_BOOTSTRAP=false
SKIP_KUBECTL=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_usage
            exit 0
            ;;
        -d|--destroy)
            DESTROY_MODE=true
            shift
            ;;
        -p|--plan-only)
            PLAN_ONLY=true
            shift
            ;;
        -s|--skip-bootstrap)
            SKIP_BOOTSTRAP=true
            shift
            ;;
        --no-kubectl)
            SKIP_KUBECTL=true
            shift
            ;;
        *)
            print_error "Unknown option: $1"
            show_usage
            exit 1
            ;;
    esac
done

# Validate prerequisites
validate_prerequisites() {
    print_status "Validating prerequisites..."
    
    local errors=0
    
    # Check if we're in the right directory
    if [[ ! -f "$SCRIPT_DIR/main.tf" ]]; then
        print_error "main.tf not found in $SCRIPT_DIR"
        ((errors++))
    fi
    
    if [[ ! -f "$SCRIPT_DIR/.env" ]]; then
        print_error ".env file not found. Please copy .env.template and configure your OpenStack credentials"
        ((errors++))
    fi
    
    # Check required tools
    if ! command -v tofu &> /dev/null; then
        print_error "OpenTofu (tofu) is not installed or not in PATH"
        print_error "Install from: https://opentofu.org/docs/intro/install/"
        ((errors++))
    fi
    
    if ! command -v kubectl &> /dev/null && [[ "$SKIP_KUBECTL" == false ]]; then
        print_error "kubectl is not installed or not in PATH"
        print_error "Install from: https://kubernetes.io/docs/tasks/tools/"
        ((errors++))
    fi
    
    if ! command -v ssh &> /dev/null && [[ "$SKIP_BOOTSTRAP" == false ]]; then
        print_error "ssh is not installed or not in PATH"
        ((errors++))
    fi
    
    # Check cloud-init file
    if [[ ! -f "$SCRIPT_DIR/k8s-cloud-init.yaml" ]]; then
        print_error "k8s-cloud-init.yaml not found"
        ((errors++))
    fi
    
    if [[ $errors -gt 0 ]]; then
        print_error "Prerequisites validation failed with $errors error(s)"
        exit 1
    fi
    
    print_success "Prerequisites validation passed"
}

# Initialize Terraform
init_terraform() {
    print_status "Initializing Terraform..."
    
    cd "$SCRIPT_DIR"
    
    if ./tofu-with-env.sh init; then
        print_success "Terraform initialized successfully"
    else
        print_error "Terraform initialization failed"
        exit 1
    fi
}

# Deploy or destroy infrastructure
manage_infrastructure() {
    cd "$SCRIPT_DIR"
    
    if [[ "$DESTROY_MODE" == true ]]; then
        print_header "DESTROYING INFRASTRUCTURE"
        print_warning "This will destroy all resources including:"
        print_warning "- All Kubernetes nodes and data"
        print_warning "- Floating IPs and networks"
        print_warning "- Storage volumes and snapshots"
        echo
        read -p "Are you sure you want to continue? (yes/no): " confirm
        
        if [[ "$confirm" != "yes" ]]; then
            print_status "Operation cancelled"
            exit 0
        fi
        
        print_status "Destroying OpenStack infrastructure..."
        if ./tofu-with-env.sh destroy -auto-approve; then
            print_success "Infrastructure destroyed successfully"
            exit 0
        else
            print_error "Infrastructure destruction failed"
            exit 1
        fi
        
    elif [[ "$PLAN_ONLY" == true ]]; then
        print_header "TERRAFORM PLAN"
        ./tofu-with-env.sh plan
        print_status "Plan complete. Use '$0' (without --plan-only) to apply changes."
        exit 0
        
    else
        print_header "DEPLOYING INFRASTRUCTURE"
        print_status "Deploying OpenStack infrastructure with automated Kubernetes bootstrap..."
        
        if ./tofu-with-env.sh apply -auto-approve; then
            print_success "Infrastructure deployed successfully"
        else
            print_error "Infrastructure deployment failed"
            exit 1
        fi
    fi
}

# Wait for infrastructure to be ready
wait_for_infrastructure() {
    print_status "Waiting for infrastructure to be accessible..."
    
    # Get master floating IP
    local master_ip
    for i in {1..30}; do
        master_ip=$(./tofu-with-env.sh output -raw master_floating_ip 2>/dev/null | tail -n 1 || echo "")
        if [[ -n "$master_ip" && "$master_ip" != *"Error"* ]]; then
            break
        fi
        print_progress "Attempt $i: Waiting for Terraform outputs..."
        sleep 10
    done
    
    if [[ -z "$master_ip" ]]; then
        print_error "Could not retrieve master floating IP"
        exit 1
    fi
    
    print_success "Master floating IP: $master_ip"
    
    # Wait for SSH connectivity
    print_status "Waiting for SSH connectivity to master node..."
    for i in {1..60}; do
        if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no ubuntu@"$master_ip" "echo 'SSH ready'" &>/dev/null; then
            print_success "SSH connectivity established"
            return 0
        fi
        print_progress "Attempt $i: Waiting for SSH connectivity..."
        sleep 15
    done
    
    print_error "SSH connectivity timeout"
    exit 1
}

# Monitor bootstrap process
monitor_bootstrap() {
    if [[ "$SKIP_BOOTSTRAP" == true ]]; then
        print_status "Skipping bootstrap monitoring as requested"
        return 0
    fi
    
    print_header "MONITORING KUBERNETES BOOTSTRAP"
    
    # Use the bootstrap script
    if [[ -f "$SCRIPT_DIR/bootstrap-k8s.sh" ]]; then
        print_status "Starting bootstrap monitoring script..."
        if "$SCRIPT_DIR/bootstrap-k8s.sh"; then
            print_success "Bootstrap monitoring completed successfully"
        else
            print_error "Bootstrap monitoring failed"
            print_status "You can check the status manually by running:"
            print_status "  ./bootstrap-k8s.sh"
            exit 1
        fi
    else
        print_warning "bootstrap-k8s.sh not found, skipping bootstrap monitoring"
    fi
}

# Setup kubectl (simplified version if bootstrap script is not available)
setup_kubectl_fallback() {
    if [[ "$SKIP_KUBECTL" == true ]]; then
        print_status "Skipping kubectl setup as requested"
        return 0
    fi
    
    print_header "SETTING UP KUBECTL ACCESS"
    
    if [[ -f "$SCRIPT_DIR/setup-kubectl.sh" ]]; then
        print_status "Using setup-kubectl.sh script..."
        if "$SCRIPT_DIR/setup-kubectl.sh"; then
            print_success "kubectl setup completed successfully"
        else
            print_warning "kubectl setup script failed, manual setup may be required"
        fi
    else
        print_warning "setup-kubectl.sh not found, manual kubectl setup required"
    fi
}

# Show final status and next steps
show_completion() {
    print_header "DEPLOYMENT COMPLETED"
    
    # Get cluster info
    local master_ip=$(./tofu-with-env.sh output -raw master_floating_ip 2>/dev/null | tail -n 1 || echo "unknown")
    local cluster_name=$(./tofu-with-env.sh output -json cluster_info 2>/dev/null | jq -r '.cluster_name' || echo "openstudio-server")
    
    echo
    print_success "OpenStack Kubernetes cluster is ready!"
    echo
    print_status "Cluster Information:"
    echo "  • Cluster Name: $cluster_name"
    echo "  • Master IP: $master_ip"
    echo "  • API Server: https://$master_ip:6443"
    echo
    print_status "Useful Commands:"
    echo "  • Check cluster: kubectl get nodes"
    echo "  • View pods: kubectl get pods --all-namespaces"
    echo "  • SSH to master: ssh ubuntu@$master_ip"
    echo
    print_status "Next Steps:"
    echo "  1. Verify cluster status: kubectl get nodes"
    echo "  2. Install OpenStudio Server: Use Helm charts from ../charts/"
    echo "  3. Configure storage: Create OpenStack credentials secret if needed"
    echo
    print_status "Troubleshooting:"
    echo "  • Bootstrap logs: ssh ubuntu@$master_ip 'sudo tail -f /var/log/cloud-init-output.log'"
    echo "  • Re-run bootstrap: ./bootstrap-k8s.sh"
    echo "  • Re-configure kubectl: ./setup-kubectl.sh"
    echo
}

# Main execution function
main() {
    # Change to script directory
    cd "$SCRIPT_DIR"
    
    print_header "OPENSTUDIO SERVER KUBERNETES DEPLOYMENT"
    echo
    print_status "Starting automated deployment process..."
    echo
    
    # Validate prerequisites
    validate_prerequisites
    echo
    
    # Initialize Terraform
    init_terraform
    echo
    
    # Deploy or destroy infrastructure
    manage_infrastructure
    
    # Only continue with bootstrap if we're not destroying
    if [[ "$DESTROY_MODE" != true && "$PLAN_ONLY" != true ]]; then
        echo
        
        # Wait for infrastructure
        wait_for_infrastructure
        echo
        
        # Monitor bootstrap
        monitor_bootstrap
        echo
        
        # Setup kubectl if bootstrap was skipped
        if [[ "$SKIP_BOOTSTRAP" == true ]]; then
            setup_kubectl_fallback
            echo
        fi
        
        # Show completion status
        show_completion
    fi
}

# Handle script interruption
trap 'print_error "Script interrupted by user"; exit 130' INT

# Run main function
main "$@"
