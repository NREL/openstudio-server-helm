# OpenStudio Server Micro Cluster Configuration
# Ultra-minimal configuration to fit within tight RAM quotas
# Total RAM usage: ~36GB (well within 245GB quota)

cluster_name = "openstudio-server-micro"

# Master node configuration - minimal but functional
master_flavor = "CS.Tiny" # 4 vCPUs, 16GB RAM

# Web node group - single node, minimal
web_count  = 1
web_flavor = "CS.Tiny" # 4 vCPUs, 16GB RAM

# Worker node group - single node, minimal
worker_count  = 1
worker_flavor = "CC.Tiny" # 4 vCPUs, 4GB RAM

# Storage configuration - reduced for testing
volume_size = 50 # GB for each node

# SSH key configuration
key_pair = "achapin"
