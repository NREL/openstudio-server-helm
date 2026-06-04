# Simplified OpenStack Infrastructure for Kubespray Kubernetes Deployment
#
# This creates basic Ubuntu instances with SSH access for Kubespray to configure

provider "openstack" {
  user_name           = var.openstack_user_name
  password            = var.openstack_password
  auth_url            = var.openstack_auth_url
  tenant_name         = var.openstack_tenant_name
  user_domain_name    = var.openstack_user_domain_name
  project_domain_id   = var.openstack_project_domain_id
  tenant_id           = var.openstack_project_id
  region              = var.openstack_region
}

# Create a network
resource "openstack_networking_network_v2" "k8s_network" {
  name           = "${var.cluster_name}-network"
  admin_state_up = "true"
}

# Create a subnet
resource "openstack_networking_subnet_v2" "k8s_subnet" {
  name       = "${var.cluster_name}-subnet"
  network_id = openstack_networking_network_v2.k8s_network.id
  cidr       = "10.0.1.0/24"
  ip_version = 4
  # Remove external DNS servers since port 53 is blocked by network policy
  # Let OpenStack provide default DNS servers or use none
  # dns_nameservers = []
}

# Get external network for router gateway
data "openstack_networking_network_v2" "external_network" {
  name = "external"
}

# Create a router for external connectivity
resource "openstack_networking_router_v2" "k8s_router" {
  name                = "${var.cluster_name}-router"
  admin_state_up      = true
  external_network_id = data.openstack_networking_network_v2.external_network.id
}

# Attach the subnet to the router
resource "openstack_networking_router_interface_v2" "k8s_router_interface" {
  router_id = openstack_networking_router_v2.k8s_router.id
  subnet_id = openstack_networking_subnet_v2.k8s_subnet.id
}

# Create a security group with basic access
resource "openstack_networking_secgroup_v2" "k8s_secgroup" {
  name        = "${var.cluster_name}-secgroup"
  description = "Security group for Kubespray Kubernetes cluster"
}

# SSH access
resource "openstack_networking_secgroup_rule_v2" "ssh_access" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 22
  port_range_max    = 22
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = openstack_networking_secgroup_v2.k8s_secgroup.id
}

# ICMP for ping testing
resource "openstack_networking_secgroup_rule_v2" "icmp_access" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "icmp"
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = openstack_networking_secgroup_v2.k8s_secgroup.id
}

# Kubernetes API server access
resource "openstack_networking_secgroup_rule_v2" "k8s_api_access" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 6443
  port_range_max    = 6443
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = openstack_networking_secgroup_v2.k8s_secgroup.id
}

# Internal communication (all ports between cluster nodes)
resource "openstack_networking_secgroup_rule_v2" "internal_all" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 1
  port_range_max    = 65535
  remote_ip_prefix  = "10.0.1.0/24"
  security_group_id = openstack_networking_secgroup_v2.k8s_secgroup.id
}

# Pod network communication (allow pod network to access hosts)
resource "openstack_networking_secgroup_rule_v2" "pod_network_internal" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 1
  port_range_max    = 65535
  remote_ip_prefix  = "10.244.0.0/16"
  security_group_id = openstack_networking_secgroup_v2.k8s_secgroup.id
}

# NodePort range for Kubernetes services (30000-32767)
resource "openstack_networking_secgroup_rule_v2" "nodeport_http" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 30749
  port_range_max    = 30749
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = openstack_networking_secgroup_v2.k8s_secgroup.id
}

# NodePort HTTPS for OpenStudio Server
resource "openstack_networking_secgroup_rule_v2" "nodeport_https" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 31385
  port_range_max    = 31385
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = openstack_networking_secgroup_v2.k8s_secgroup.id
}

# General NodePort range (optional - allows any NodePort services)
resource "openstack_networking_secgroup_rule_v2" "nodeport_range" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 30000
  port_range_max    = 32767
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = openstack_networking_secgroup_v2.k8s_secgroup.id
}

# Get the Ubuntu image
data "openstack_images_image_v2" "ubuntu_image" {
  name        = var.image_name
  most_recent = true
}

# Enhanced cloud-init with corporate firewall detection and workarounds
locals {
  user_data = base64encode(templatefile("${path.module}/corporate-firewall-cloud-init.yaml", {
    public_key = var.public_key
  }))
}

# Floating IPs for external access
resource "openstack_networking_floatingip_v2" "master_fip" {
  pool = "external"
}

resource "openstack_networking_floatingip_v2" "worker_fip" {
  count = var.worker_count
  pool  = "external"
}

resource "openstack_networking_floatingip_v2" "web_fip" {
  count = var.web_count
  pool  = "external"
}

# Create volumes for instances (required for CS.Tiny flavor with zero disk)
resource "openstack_blockstorage_volume_v3" "master_volume" {
  name = "${var.cluster_name}-master-volume"
  size = var.volume_size
  image_id = data.openstack_images_image_v2.ubuntu_image.id
}

resource "openstack_blockstorage_volume_v3" "worker_volume" {
  count = var.worker_count
  name  = "${var.cluster_name}-worker-${count.index + 1}-volume"
  size  = var.volume_size
  image_id = data.openstack_images_image_v2.ubuntu_image.id
}

resource "openstack_blockstorage_volume_v3" "web_volume" {
  count = var.web_count
  name  = "${var.cluster_name}-web-${count.index + 1}-volume"
  size  = var.volume_size
  image_id = data.openstack_images_image_v2.ubuntu_image.id
}

# Create network ports for proper floating IP association
resource "openstack_networking_port_v2" "master_port" {
  name           = "${var.cluster_name}-master-port"
  network_id     = openstack_networking_network_v2.k8s_network.id
  admin_state_up = "true"
  security_group_ids = [openstack_networking_secgroup_v2.k8s_secgroup.id]

  fixed_ip {
    subnet_id = openstack_networking_subnet_v2.k8s_subnet.id
  }
}

resource "openstack_networking_port_v2" "worker_port" {
  count          = var.worker_count
  name           = "${var.cluster_name}-worker-${count.index + 1}-port"
  network_id     = openstack_networking_network_v2.k8s_network.id
  admin_state_up = "true"
  security_group_ids = [openstack_networking_secgroup_v2.k8s_secgroup.id]

  fixed_ip {
    subnet_id = openstack_networking_subnet_v2.k8s_subnet.id
  }
}

resource "openstack_networking_port_v2" "web_port" {
  count          = var.web_count
  name           = "${var.cluster_name}-web-${count.index + 1}-port"
  network_id     = openstack_networking_network_v2.k8s_network.id
  admin_state_up = "true"
  security_group_ids = [openstack_networking_secgroup_v2.k8s_secgroup.id]

  fixed_ip {
    subnet_id = openstack_networking_subnet_v2.k8s_subnet.id
  }
}

# Master node
resource "openstack_compute_instance_v2" "k8s_master" {
  name        = "${var.cluster_name}-master"
  flavor_name = var.master_flavor
  key_pair    = var.key_pair
  user_data   = local.user_data

  block_device {
    uuid                  = openstack_blockstorage_volume_v3.master_volume.id
    source_type           = "volume"
    destination_type      = "volume"
    boot_index            = 0
    delete_on_termination = true
  }

  network {
    port = openstack_networking_port_v2.master_port.id
  }

  depends_on = [openstack_networking_router_interface_v2.k8s_router_interface]
}

# Worker nodes
resource "openstack_compute_instance_v2" "k8s_worker" {
  count       = var.worker_count
  name        = "${var.cluster_name}-worker-${count.index + 1}"
  flavor_name = var.worker_flavor
  key_pair    = var.key_pair
  user_data   = local.user_data

  block_device {
    uuid                  = openstack_blockstorage_volume_v3.worker_volume[count.index].id
    source_type           = "volume"
    destination_type      = "volume"
    boot_index            = 0
    delete_on_termination = true
  }

  network {
    port = openstack_networking_port_v2.worker_port[count.index].id
  }

  depends_on = [openstack_networking_router_interface_v2.k8s_router_interface]
}

# Web nodes  
resource "openstack_compute_instance_v2" "k8s_web" {
  count       = var.web_count
  name        = "${var.cluster_name}-web-${count.index + 1}"
  flavor_name = var.web_flavor
  key_pair    = var.key_pair
  user_data   = local.user_data

  block_device {
    uuid                  = openstack_blockstorage_volume_v3.web_volume[count.index].id
    source_type           = "volume"
    destination_type      = "volume"
    boot_index            = 0
    delete_on_termination = true
  }

  network {
    port = openstack_networking_port_v2.web_port[count.index].id
  }

  depends_on = [openstack_networking_router_interface_v2.k8s_router_interface]
}

# Associate floating IPs
resource "openstack_networking_floatingip_associate_v2" "master_fip_assoc" {
  floating_ip = openstack_networking_floatingip_v2.master_fip.address
  port_id     = openstack_networking_port_v2.master_port.id
  depends_on  = [openstack_compute_instance_v2.k8s_master]
}

resource "openstack_networking_floatingip_associate_v2" "worker_fip_assoc" {
  count       = var.worker_count
  floating_ip = openstack_networking_floatingip_v2.worker_fip[count.index].address
  port_id     = openstack_networking_port_v2.worker_port[count.index].id
  depends_on  = [openstack_compute_instance_v2.k8s_worker]
}

resource "openstack_networking_floatingip_associate_v2" "web_fip_assoc" {
  count       = var.web_count
  floating_ip = openstack_networking_floatingip_v2.web_fip[count.index].address
  port_id     = openstack_networking_port_v2.web_port[count.index].id
  depends_on  = [openstack_compute_instance_v2.k8s_web]
}
