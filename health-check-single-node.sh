#!/bin/bash

# Health Check Script for Single-Node OpenStudio Server Deployment
# Validates resource requirements, scheduling constraints, and deployment readiness

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="${NAMESPACE:-default}"
CHART_DIR="$SCRIPT_DIR/openstudio-server"

echo "================================"
echo "OpenStudio Server Health Check"
echo "================================"
echo ""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

pass() {
    echo -e "${GREEN}✓${NC} $1"
}

fail() {
    echo -e "${RED}✗${NC} $1"
}

warn() {
    echo -e "${YELLOW}⚠${NC} $1"
}

# Function to calculate total resource requirements
calculate_resources() {
    echo ""
    echo "Resource Requirements Summary:"
    echo "=============================="
    
    # Extract resource values using grep and awk
    local web_cpu=$(grep -A10 "^web:" "$CHART_DIR/values.yaml" | grep "cpu:" | head -1 | awk '{print $2}' | tr -d '"')
    local web_mem=$(grep -A10 "^web:" "$CHART_DIR/values.yaml" | grep "memory:" | head -1 | awk '{print $2}' | tr -d '"Gi')
    
    local web_bg_cpu=$(grep -A10 "^web_background:" "$CHART_DIR/values.yaml" | grep "cpu:" | head -1 | awk '{print $2}' | tr -d '"')
    local web_bg_mem=$(grep -A10 "^web_background:" "$CHART_DIR/values.yaml" | grep "memory:" | head -1 | awk '{print $2}' | tr -d '"Gi')
    
    local db_cpu=$(grep -A5 "^db:" "$CHART_DIR/values.yaml" | grep "cpu:" | head -1 | awk '{print $2}' | tr -d '"')
    local db_mem=$(grep -A5 "^db:" "$CHART_DIR/values.yaml" | grep "memory:" | head -1 | awk '{print $2}' | tr -d '"Gi')
    
    local redis_cpu=$(grep -A10 "^redis:" "$CHART_DIR/values.yaml" | grep "cpu:" | head -1 | awk '{print $2}' | tr -d '"')
    local redis_mem=$(grep -A10 "^redis:" "$CHART_DIR/values.yaml" | grep "memory:" | head -1 | awk '{print $2}' | tr -d '"Gi')
    
    local rserve_cpu=$(grep -A10 "^rserve:" "$CHART_DIR/values.yaml" | grep "cpu:" | head -1 | awk '{print $2}' | tr -d '"')
    local rserve_mem=$(grep -A10 "^rserve:" "$CHART_DIR/values.yaml" | grep "memory:" | head -1 | awk '{print $2}' | tr -d '"Gi')
    
    echo ""
    echo "Deployment         CPU    Memory"
    echo "------------ -------- ----------"
    printf "web             %6s   %6sGi\n" "$web_cpu" "$web_mem"
    printf "web-background  %6s   %6sGi\n" "$web_bg_cpu" "$web_bg_mem"
    printf "db              %6s   %6sGi\n" "$db_cpu" "$db_mem"
    printf "redis           %6s   %6sGi\n" "$redis_cpu" "$redis_mem"
    printf "rserve          %6s   %6sGi\n" "$rserve_cpu" "$rserve_mem"
    echo "------------ -------- ----------"
    
    # Simple sum (basic math)
    local total_cpu=$(echo "$web_cpu + $web_bg_cpu + $db_cpu + $redis_cpu + $rserve_cpu" | bc)
    local total_mem=$(echo "$web_mem + $web_bg_mem + $db_mem + $redis_mem + $rserve_mem" | bc)
    
    printf "TOTAL           %6s   %6sGi\n" "$total_cpu" "$total_mem"
    echo ""
    
    if (( $(echo "$total_cpu > 32" | bc -l) )); then
        warn "Total CPU requirements ($total_cpu) exceed typical single node capacity (32)"
    else
        pass "Total CPU requirements ($total_cpu) fit within typical single node"
    fi
    
    if (( $(echo "$total_mem > 128" | bc -l) )); then
        warn "Total memory requirements (${total_mem}Gi) exceed typical single node capacity (128Gi)"
    else
        pass "Total memory requirements (${total_mem}Gi) fit within typical single node"
    fi
}

# Check that all deployments have web-group nodegroup affinity
check_affinities() {
    echo ""
    echo "Checking Node Affinities:"
    echo "========================="
    
    local deploy_files=(
        "web/web-deploy.yaml"
        "web-background/web-background-deploy.yaml"
        "db/db-deploy.yaml"
        "redis/redis-deploy.yaml"
        "rserve/rserve-deploy.yaml"
    )
    
    for file in "${deploy_files[@]}"; do
        local full_path="$CHART_DIR/templates/$file"
        if [ -f "$full_path" ]; then
            if grep -q "web-group" "$full_path"; then
                pass "$file has web-group affinity"
            else
                fail "$file missing web-group affinity"
            fi
        else
            fail "$file not found"
        fi
    done
    
    # Check NFS provisioner affinity in values
    if grep -q "web-group" "$CHART_DIR/charts/nfs-server-provisioner/values.yaml"; then
        pass "nfs-server-provisioner has web-group affinity"
    else
        fail "nfs-server-provisioner missing web-group affinity"
    fi
}

# Check priority classes
check_priority() {
    echo ""
    echo "Checking Priority Classes:"
    echo "=========================="
    
    if kubectl get priorityclass high-priority -n "$NAMESPACE" &>/dev/null; then
        pass "high-priority PriorityClass exists"
    else
        warn "high-priority PriorityClass not found (may not be deployed yet)"
    fi
}

# Check storage classes
check_storage() {
    echo ""
    echo "Checking Storage Classes:"
    echo "========================"
    
    if kubectl get storageclass ssd -n "$NAMESPACE" &>/dev/null; then
        pass "ssd StorageClass exists"
    else
        warn "ssd StorageClass not found (may not be deployed yet)"
    fi
    
    if kubectl get storageclass nfs -n "$NAMESPACE" &>/dev/null; then
        pass "nfs StorageClass exists"
    else
        warn "nfs StorageClass not found (may not be deployed yet)"
    fi
}

# Check that replicas are set for single node
check_replicas() {
    echo ""
    echo "Checking Replica Counts:"
    echo "========================"
    
    # Check HPA settings for web
    local web_hpa_min=$(grep -A5 "^web_hpa:" "$CHART_DIR/values.yaml" | grep "minReplicas" | awk '{print $2}')
    local web_hpa_max=$(grep -A5 "^web_hpa:" "$CHART_DIR/values.yaml" | grep "maxReplicas" | awk '{print $2}')
    
    if [ "$web_hpa_max" = "1" ]; then
        pass "web HPA maxReplicas is 1 (good for single node)"
    else
        warn "web HPA maxReplicas is $web_hpa_max (should be 1 for single node)"
    fi
    
    # Check web-background replicas
    local bg_replicas=$(grep -A5 "^web_background:" "$CHART_DIR/values.yaml" | grep "replicas" | awk '{print $2}')
    if [ "$bg_replicas" = "1" ]; then
        pass "web-background replicas is 1"
    else
        warn "web-background replicas is $bg_replicas (should be 1 for single node)"
    fi
}

# Main execution
echo ""
echo "Starting health checks..."
echo ""

calculate_resources
check_affinities
check_priority
check_storage
check_replicas

echo ""
echo "================================"
echo "Health Check Complete"
echo "================================"
echo ""
echo "Next steps:"
echo "1. Deploy the Helm chart: helm install openstudio-server ./openstudio-server -n default"
echo "2. Monitor deployment: kubectl get pods -n default -w"
echo "3. Check pod events: kubectl describe pod <pod-name> -n default"
echo ""
