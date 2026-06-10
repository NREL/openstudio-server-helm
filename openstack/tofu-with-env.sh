#!/bin/bash

# OpenTofu wrapper script that automatically loads environment variables
# Usage: ./tofu-with-env.sh plan
#        ./tofu-with-env.sh apply
#        ./tofu-with-env.sh destroy

set -e

# Check if .env file exists
if [ ! -f ".env" ]; then
    echo "❌ Error: .env file not found!"
    echo ""
    echo "Please create a .env file from the template:"
    echo "  cp .env.template .env"
    echo "  # Edit .env with your credentials"
    echo ""
    exit 1
fi

# Load environment variables
echo "📄 Loading environment variables from .env..."
set -a
source .env
set +a
# Verify required variables are set
if [ -z "$TF_VAR_openstack_user_name" ] || [ -z "$TF_VAR_openstack_password" ] || [ -z "$TF_VAR_openstack_tenant_name" ]; then
    echo "❌ Error: Missing required environment variables!"
    echo ""
    echo "Please check your .env file contains:"
    echo "  TF_VAR_openstack_user_name"
    echo "  TF_VAR_openstack_password"
    echo "  TF_VAR_openstack_tenant_name"
    echo ""
    exit 1
fi

# Add default flavor variables if not set
export TF_VAR_master_flavor="${TF_VAR_master_flavor:-CS.Wee}"
export TF_VAR_web_flavor="${TF_VAR_web_flavor:-CS.2XMedium}"
export TF_VAR_worker_flavor="${TF_VAR_worker_flavor:-CM.XLarge}"

echo "✅ Environment variables loaded successfully"
echo "🚀 Running: tofu $@"
echo ""

# Run tofu with the provided arguments
tofu "$@"
