#!/bin/bash
# Helper script to find available OpenStack images
# Usage: source find-images.sh

if ! command -v openstack &> /dev/null; then
    echo "ERROR: openstack CLI not installed"
    exit 1
fi

# Source OpenStack credentials if available
OPENRC_FILE="${1:-./../aurora-179d-openrc.sh}"
if [[ -f "$OPENRC_FILE" ]]; then
    echo "Loading OpenStack credentials from $OPENRC_FILE..."
    source "$OPENRC_FILE"
fi

echo ""
echo "Available Ubuntu images in OpenStack:"
echo "========================================"
openstack image list --format table | grep -i ubuntu

echo ""
echo "To use a specific image, set TF_VAR_image_name or add to tfvars file:"
echo "  export TF_VAR_image_name='ubuntu-jammy-kube-v1.33.2-250701-1108'"
echo "  or in openstudio-large.tfvars:"
echo "  image_name = \"ubuntu-jammy-kube-v1.33.2-250701-1108\""
echo ""
