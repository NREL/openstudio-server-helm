# OpenStudio Server Small Cluster Configuration
# Quota-conscious configuration: Total RAM ~84GB

cluster_name = "openstudio-server-small"
# Replace with your OpenStack identity endpoint URL.
openstack_auth_url = "https://REPLACE_WITH_YOUR_OPENSTACK_API:5000"

# Master node configuration
master_flavor = "CS.Wee" # 8 vCPUs, 32GB RAM

# Web node group - for web interface and API
web_count  = 2
web_flavor = "CS.Tiny" # 4 vCPUs, 16GB RAM each (32GB total)

# Worker node group - for computation
worker_count  = 1
worker_flavor = "shared_c8m16d50" # 8 vCPUs, 16GB RAM

# Storage configuration
volume_size = 100 # GB for each node

# SSH key configuration
key_pair = "<your-openstack-keypair-name>"
