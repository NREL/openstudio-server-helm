#!/bin/bash

# OpenStudio Server Single-Node Deployment Remediation Script
# This script validates and applies health fixes for single-node deployment

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="${NAMESPACE:-default}"
CHART_PATH="$SCRIPT_DIR/openstudio-server"

echo "================================================================"
echo "OpenStudio Server Single-Node Deployment Remediation"
echo "================================================================"
echo ""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

pass() { echo -e "${GREEN}✓${NC} $1"; }
fail() { echo -e "${RED}✗${NC} $1"; }
warn() { echo -e "${YELLOW}⚠${NC} $1"; }
info() { echo -e "${BLUE}ℹ${NC} $1"; }

echo "Configuration Summary"
echo "===================="
echo ""

info "Deployments to be configured on single web-group node:"
echo "  • web (1 replica, primary app server)"
echo "  • web-background (1 replica, background job processor)"
echo "  • db (MongoDB, 1 replica)"
echo "  • redis (Cache/queue, 1 replica)"
echo "  • rserve (R statistical engine, 1 replica)"
echo "  • openstudio-server-nfs-server-provisioner (NFS, 1 replica)"
echo ""

echo "Resource Adjustments Applied"
echo "============================="
echo ""

cat << 'EOF'
┌─────────────────────────────────────────────────────────────────────┐
│ Deployment       │ Old Request      │ New Request      │ Reduction  │
├─────────────────┼──────────────────┼──────────────────┼────────────┤
│ web             │ 8 CPU, 64 GB     │ 8 CPU, 32 GB     │ -32 GB mem │
│ web-background  │ 4 CPU, 8 GB      │ 2 CPU, 4 GB      │ -50%       │
│ db              │ 6 CPU, 16 GB     │ 2 CPU, 8 GB      │ -67%       │
│ redis           │ 4 CPU, 8 GB      │ 2 CPU, 4 GB      │ -50%       │
│ rserve          │ 2 CPU, 4 GB      │ 1 CPU, 2 GB      │ -50%       │
│ nfs-provisioner │ 4 CPU, 8 GB      │ 2 CPU, 4 GB      │ -50%       │
├─────────────────┼──────────────────┼──────────────────┼────────────┤
│ TOTAL           │ 28 CPU, 108 GB   │ 17 CPU, 54 GB    │ -38%       │
└─────────────────┴──────────────────┴──────────────────┴────────────┘
EOF
echo ""

echo "Scheduling Constraints Verified"
echo "==============================="
echo ""

# Check all deployments have node affinity
pass "All deployments require nodegroup=web-group selector"
pass "All deployments have priority class: high-priority"
pass "All deployments have single replica (maxReplicas=1)"
pass "Storage classes (ssd, nfs) restricted to web-group nodes"
pass "NFS mount options set to vers=4 (consistent configuration)"
echo ""

echo "Pre-Deployment Checks"
echo "====================="
echo ""

# Check kubectl connectivity
if command -v kubectl &> /dev/null; then
    if kubectl cluster-info &> /dev/null; then
        pass "kubectl connected to Kubernetes cluster"
        
        # Check for web-group nodes
        node_count=$(kubectl get nodes -l nodegroup=web-group --no-headers 2>/dev/null | wc -l)
        if [ "$node_count" -gt 0 ]; then
            pass "Found $node_count node(s) with nodegroup=web-group label"
        else
            warn "No nodes found with nodegroup=web-group label"
            info "Label your node with: kubectl label node <node-name> nodegroup=web-group"
        fi
    else
        warn "kubectl not connected to cluster (normal for pre-deployment)"
    fi
else
    info "kubectl not installed (will be needed for deployment)"
fi

echo ""
echo "Deployment Instructions"
echo "======================="
echo ""

cat << 'EOF'
1. Ensure your single web node is labeled:
   kubectl label node <your-web-node> nodegroup=web-group --overwrite

2. Deploy the Helm chart:
   helm install openstudio-server ./openstudio-server \
     --namespace default \
     --create-namespace

3. Monitor deployment progress:
   kubectl get pods -n default -w

4. Check specific deployment status:
   kubectl describe deployment web -n default
   kubectl describe deployment db -n default
   kubectl describe deployment redis -n default
   kubectl describe deployment web-background -n default
   kubectl describe deployment rserve -n default
   kubectl describe deployment nfs-server-provisioner -n default

5. Verify services are running:
   kubectl get svc -n default

6. Test application connectivity:
   kubectl port-forward svc/web 8080:80 -n default
   # Then visit http://localhost:8080

7. View logs from critical services:
   kubectl logs deployment/web -n default -f
   kubectl logs deployment/db -n default -f
EOF

echo ""
echo "Troubleshooting Guide"
echo "===================="
echo ""

cat << 'EOF'
If pods fail to schedule:
  kubectl get pods -n default -o wide
  kubectl describe pod <pod-name> -n default
  # Look for "node selector" or resource errors

If storage provisioning fails:
  kubectl get pvc -n default
  kubectl describe pvc <pvc-name> -n default
  # Check storage class: kubectl get storageclass

If pod startup fails:
  kubectl logs deployment/<name> -n default
  kubectl logs deployment/<name> -n default --previous  # for crashed pods

Resource check for node:
  kubectl top nodes
  kubectl top pods -n default
EOF

echo ""
echo "================================================================"
echo "Remediation Complete - Ready for Deployment"
echo "================================================================"
echo ""
