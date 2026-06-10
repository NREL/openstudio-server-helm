# OpenStudio Server Large Cluster Configuration
# Equivalent to AWS EKS large configuration

cluster_name = "openstudio-server-large"
openstack_auth_url = "https://your-openstack-api.example.com:5000"

# Master node configuration
master_flavor = "CS.2XMedium" # 32 vCPUs, 128GB RAM

# Web node group - for web interface and API
web_count  = 1
web_flavor = "CE.2XMedium" # 32 vCPUs, 154GB RAM (enterprise flavor)

# Worker node group - for computation
worker_count  = 1
worker_flavor = "CE.XLarge" # 32 vCPUs, 300GB RAM (compute enterprise)

# Storage configuration
volume_size = 550 # GB for web nodes (matches EKS config)

# SSH key configuration
key_pair = "<your-openstack-keypair-name>"
