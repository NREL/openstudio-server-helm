#!/bin/bash

# setup-kubectl.sh
# Automatically configure kubectl for OpenStack Kubernetes cluster
#
# This script:
# 1. Gets the floating IP from Terraform output
# 2. Updates kubectl configuration to use the floating IP
# 3. Sets up TLS skip for certificate issues
# 4. Tests the connection

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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

# Check if tofu is available
if ! command -v tofu &> /dev/null; then
    print_error "OpenTofu (tofu) is not installed or not in PATH"
    print_error "Please install OpenTofu: https://opentofu.org/docs/intro/install/"
    exit 1
fi

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    print_error "kubectl is not installed or not in PATH"
    print_error "Please install kubectl: https://kubernetes.io/docs/tasks/tools/"
    exit 1
fi

print_status "Setting up kubectl for OpenStack Kubernetes cluster..."

# Get the cluster information from Terraform
print_status "Retrieving cluster information from Terraform..."

# Check if we're in the right directory
if [[ ! -f "main.tf" ]]; then
    print_error "main.tf not found. Please run this script from the openstack/ directory."
    exit 1
fi

# Use the tofu-with-env.sh script if available, otherwise use tofu directly
if [[ -f "./tofu-with-env.sh" ]]; then
    TOFU_CMD="./tofu-with-env.sh"
    print_status "Using tofu-with-env.sh for environment variables"
else
    TOFU_CMD="tofu"
    print_warning "tofu-with-env.sh not found, using tofu directly"
    print_warning "Make sure your OpenStack environment variables are set!"
fi

# Get the floating IP
print_status "Extracting floating IP from Terraform output..."
FLOATING_IP=$(${TOFU_CMD} output -raw master_floating_ip 2>/dev/null | tail -n 1)
if [[ -z "$FLOATING_IP" || "$FLOATING_IP" == *"Error"* ]]; then
    print_error "Could not retrieve master_floating_ip from Terraform output"
    print_error "Make sure your infrastructure is deployed and Terraform state is available"
    print_error "Output was: $FLOATING_IP"
    exit 1
fi

print_success "Found master floating IP: $FLOATING_IP"

# Test connectivity to the API server
print_status "Testing connectivity to Kubernetes API server..."
if nc -zv "$FLOATING_IP" 6443 &>/dev/null; then
    print_success "Kubernetes API server is reachable at $FLOATING_IP:6443"
else
    print_error "Cannot reach Kubernetes API server at $FLOATING_IP:6443"
    print_error "Please check:"
    print_error "  1. The cluster is fully deployed and running"
    print_error "  2. Security groups allow port 6443"
    print_error "  3. The floating IP is correctly assigned"
    exit 1
fi

# Backup existing kubeconfig if it exists
KUBECONFIG_PATH="${HOME}/.kube/config"
if [[ -f "$KUBECONFIG_PATH" ]]; then
    BACKUP_PATH="${KUBECONFIG_PATH}.backup.$(date +%Y%m%d-%H%M%S)"
    print_status "Backing up existing kubeconfig to $BACKUP_PATH"
    cp "$KUBECONFIG_PATH" "$BACKUP_PATH"
fi

# List available contexts before making changes
print_status "Current kubectl contexts:"
kubectl config get-contexts 2>/dev/null || print_warning "No existing kubectl contexts found"

# Update kubectl configuration
print_status "Updating kubectl configuration..."

# Set the cluster endpoint to use the floating IP
kubectl config set-cluster kubernetes --server="https://${FLOATING_IP}:6443"
print_success "Updated cluster endpoint to https://${FLOATING_IP}:6443"

# Skip TLS verification (since certificate is issued for private IP)
kubectl config set-cluster kubernetes --insecure-skip-tls-verify=true
print_success "Configured to skip TLS verification"

# Set the context to use (assuming it exists)
if kubectl config get-contexts kubernetes-admin@kubernetes &>/dev/null; then
    kubectl config use-context kubernetes-admin@kubernetes
    print_success "Switched to context: kubernetes-admin@kubernetes"
else
    print_warning "Context 'kubernetes-admin@kubernetes' not found"
    print_warning "Available contexts:"
    kubectl config get-contexts
    echo
    print_warning "You may need to manually switch to the correct context with:"
    print_warning "kubectl config use-context <context-name>"
fi

# Test the connection
print_status "Testing kubectl connection..."
if kubectl cluster-info &>/dev/null; then
    print_success "kubectl is now configured and working!"
    echo
    print_status "Cluster information:"
    kubectl cluster-info
    echo
    print_status "Node status:"
    kubectl get nodes
else
    print_error "kubectl configuration failed"
    print_error "Please check the troubleshooting section in the README.md"
    exit 1
fi

echo
print_success "kubectl setup complete!"
print_status "You can now use kubectl to manage your OpenStack Kubernetes cluster"
print_warning "Note: TLS verification is disabled due to certificate/floating IP mismatch"
print_status "For more secure access, consider using 'kubectl proxy' through an SSH tunnel"
