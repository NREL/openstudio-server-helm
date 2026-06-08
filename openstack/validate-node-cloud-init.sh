#!/bin/bash
# validate-node-cloud-init.sh
# 
# Run this script on a new node to validate that it has the correct cloud-init
# with registry mirrors removed and images pre-cached.
#
# Usage: scp validate-node-cloud-init.sh ubuntu@<node-ip>:~/
#        ssh ubuntu@<node-ip>
#        bash ~/validate-node-cloud-init.sh

set -e

echo "=========================================="
echo "NEW NODE VALIDATION SCRIPT"
echo "=========================================="
echo ""

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

PASS=0
FAIL=0

check_item() {
    local name=$1
    local cmd=$2
    
    if eval "$cmd" &>/dev/null; then
        echo -e "${GREEN}✅${NC} $name"
        ((PASS++))
    else
        echo -e "${RED}❌${NC} $name"
        ((FAIL++))
    fi
}

check_output() {
    local name=$1
    local cmd=$2
    local expected=$3
    
    local output=$(eval "$cmd" 2>/dev/null || true)
    if echo "$output" | grep -q "$expected"; then
        echo -e "${GREEN}✅${NC} $name"
        ((PASS++))
    else
        echo -e "${RED}❌${NC} $name"
        echo "   Expected: $expected"
        echo "   Got: $output"
        ((FAIL++))
    fi
}

echo "=== 1. CHECKING CLOUD-INIT STATUS ==="
check_item "Cloud-init completed" "[ -f /var/lib/cloud/instance/boot-finished ]"
echo ""

echo "=== 2. CHECKING REGISTRY MIRRORS (SHOULD BE ABSENT) ==="
MIRRORS=$(sudo cat /etc/containerd/config.toml | grep -c "registry.mirrors" || true)
if [ "$MIRRORS" -eq 0 ]; then
    echo -e "${GREEN}✅${NC} No registry mirrors configured"
    ((PASS++))
else
    echo -e "${RED}❌${NC} Found registry mirrors (old config)"
    echo "   Check /etc/containerd/config.toml manually"
    ((FAIL++))
fi
echo ""

echo "=== 3. CHECKING FOR CACHED IMAGES ==="
IMAGES=$(sudo ctr -n k8s.io images ls 2>/dev/null | wc -l || true)
echo "Total images cached: $IMAGES"

for img in "nrel/openstudio-server" "nrel/openstudio-rserve" "mongo" "redis" "coredns"; do
    check_output "Image cached: $img" "sudo ctr -n k8s.io images ls 2>/dev/null | grep -c '$img'" "$img"
done
echo ""

echo "=== 4. CHECKING CLOUD-INIT LOG FOR PREPULL ==="
if sudo grep -q "Pulling:" /var/log/cloud-init-output.log 2>/dev/null; then
    echo -e "${GREEN}✅${NC} Cloud-init image prepull succeeded"
    echo "   Log excerpt:"
    sudo grep "Pulling:" /var/log/cloud-init-output.log | head -3 | sed 's/^/   /'
    ((PASS++))
else
    echo -e "${YELLOW}⚠️${NC} Could not verify prepull in logs"
    echo "   Check: sudo tail -200 /var/log/cloud-init-output.log"
fi
echo ""

echo "=== 5. CHECKING KUBELET STATUS ==="
check_item "Kubelet is running" "systemctl is-active kubelet"
echo ""

echo "=========================================="
echo "VALIDATION SUMMARY"
echo "=========================================="
echo -e "Passed: ${GREEN}$PASS${NC}  Failed: ${RED}$FAIL${NC}"
echo ""

if [ $FAIL -eq 0 ]; then
    echo -e "${GREEN}✅ NODE HAS CORRECT CLOUD-INIT${NC}"
    echo "Azimuth/Magnum update was successful!"
    exit 0
else
    echo -e "${RED}❌ NODE HAS OLD/INCORRECT CLOUD-INIT${NC}"
    echo "Azimuth/Magnum needs updating."
    echo "See MAGNUM_UPDATE_GUIDE.md for instructions."
    exit 1
fi
