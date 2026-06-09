# OpenStudio Server Small Cluster Configuration
# Quota-conscious configuration: Total RAM ~84GB

cluster_name = "openstudio-server-small"

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

# Image configuration (optional - uncomment and set to override default)
# image_name = "ubuntu-jammy-kube-v1.33.2-250701-1108"  # Replace with actual image name from: openstack image list
# Find available images: openstack image list | grep -i ubuntu

# SSH key configuration
key_pair = "achapin"
