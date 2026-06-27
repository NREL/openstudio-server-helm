#!/bin/bash

# Production Deployment Script for OpenStudio Server
# Before running this script, ensure your web node group has been scaled appropriately

set -e

echo "🚀 OpenStudio Server Production Deployment"
echo "=========================================="

# Check if kubectl is working
if ! kubectl get nodes &>/dev/null; then
    echo "❌ Error: kubectl is not connected to a cluster"
    exit 1
fi

# Check web node capacity
echo "📊 Checking web node group capacity..."
WEB_NODES=$(kubectl get nodes -l capi.stackhpc.com/node-group=web --no-headers 2>/dev/null | wc -l || echo "0")

if [ "$WEB_NODES" -lt 4 ]; then
    echo "⚠️  WARNING: Only $WEB_NODES web nodes found. Production configuration requires at least 4 nodes."
    echo "   Please scale your web node group before proceeding."
    echo ""
    echo "   Current resource requirements:"
    echo "   - Maximum: ~53 CPU cores, ~148Gi memory"
    echo "   - Baseline: ~30 CPU cores, ~80Gi memory"
    echo ""
    read -p "Do you want to continue anyway? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
else
    echo "✅ Found $WEB_NODES web nodes - good for production"
fi

# Show current configuration
echo ""
echo "📋 Production Configuration Summary:"
echo "   - Database: 4 CPU, 16Gi memory, 200Gi storage"
echo "   - Redis: 2 CPU, 8Gi memory, 100Gi storage"
echo "   - Web: 4 CPU, 16Gi memory, 2-4 replicas"
echo "   - Workers: 1.5 CPU, 3Gi memory, 10-500 replicas"
echo "   - NFS: 500Gi total storage"
echo ""

read -p "Proceed with deployment? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Deployment cancelled."
    exit 0
fi

# Perform the upgrade
echo ""
echo "🔄 Deploying OpenStudio Server with production configuration..."

helm upgrade --install openstudio-server ./openstudio-server \
  --values ./openstudio-server/values.yaml \
  --timeout 20m \
  --wait

if [ $? -eq 0 ]; then
    echo ""
    echo "✅ Production deployment completed successfully!"
    echo ""
    echo "📋 Next steps:"
    echo "   1. Monitor pod startup: kubectl get pods -w"
    echo "   2. Check resource usage: kubectl top nodes"
    echo "   3. Verify autoscaling: kubectl get hpa"
    echo "   4. Access web interface via load balancer"
    echo ""
    echo "🔍 Monitoring commands:"
    echo "   kubectl get pods                    # Check pod status"
    echo "   kubectl get hpa                     # Check autoscaling"
    echo "   kubectl top nodes                   # Check node resources"
    echo "   kubectl logs -f deployment/web      # Web application logs"
    echo "   kubectl logs -f deployment/worker   # Worker logs"
else
    echo ""
    echo "❌ Deployment failed. Check the logs above for details."
    exit 1
fi