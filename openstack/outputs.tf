# Output values for Kubespray deployment

output "cluster_info" {
  description = "Basic cluster information"
  value = {
    cluster_name      = var.cluster_name
    master_private_ip = openstack_networking_port_v2.master_port.all_fixed_ips[0]
    master_public_ip  = openstack_networking_floatingip_v2.master_fip.address
    total_nodes       = 1 + var.worker_count + var.web_count
    worker_node_count = var.worker_count
    web_node_count    = var.web_count
  }
}

output "master_floating_ip" {
  value = openstack_networking_floatingip_v2.master_fip.address
}

output "master_ip" {
  value = openstack_networking_port_v2.master_port.all_fixed_ips[0]
}

output "worker_floating_ips" {
  value = openstack_networking_floatingip_v2.worker_fip[*].address
}

output "worker_ips" {
  value = openstack_networking_port_v2.worker_port[*].all_fixed_ips[0]
}

output "web_floating_ips" {
  value = openstack_networking_floatingip_v2.web_fip[*].address
}

output "web_node_ips" {
  value = openstack_networking_port_v2.web_port[*].all_fixed_ips[0]
}

output "ssh_connection_info" {
  description = "SSH connection details"
  value = {
    master_ssh_command  = "ssh ubuntu@${openstack_networking_floatingip_v2.master_fip.address}"
    worker_ssh_commands = [for ip in openstack_networking_floatingip_v2.worker_fip[*].address : "ssh ubuntu@${ip}"]
    web_ssh_commands    = [for ip in openstack_networking_floatingip_v2.web_fip[*].address : "ssh ubuntu@${ip}"]
    note                = "Use your SSH private key (${var.key_pair}) for authentication"
  }
}

output "kubespray_inventory_template" {
  description = "Template for Kubespray inventory file"
  value       = <<-EOT
[all]
master ansible_host=${openstack_networking_floatingip_v2.master_fip.address} ip=${openstack_networking_port_v2.master_port.all_fixed_ips[0]}
%{for i, ip in openstack_networking_floatingip_v2.worker_fip[*].address}
worker-${i + 1} ansible_host=${ip} ip=${openstack_networking_port_v2.worker_port[i].all_fixed_ips[0]}
%{endfor}
%{for i, ip in openstack_networking_floatingip_v2.web_fip[*].address}
web-${i + 1} ansible_host=${ip} ip=${openstack_networking_port_v2.web_port[i].all_fixed_ips[0]}
%{endfor}

[kube-master]
master

[etcd]
master

[kube-node]
%{for i, ip in openstack_networking_floatingip_v2.worker_fip[*].address}
worker-${i + 1}
%{endfor}
%{for i, ip in openstack_networking_floatingip_v2.web_fip[*].address}
web-${i + 1}
%{endfor}

[calico-rr]

[k8s-cluster:children]
kube-master
kube-node
calico-rr

[k8s-cluster:vars]
ansible_user=ubuntu
ansible_ssh_private_key_file=~/.ssh/id_rsa
EOT
}
