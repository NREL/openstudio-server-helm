@description('The name of the Managed Cluster resource.')
param clusterName string = 'openstudio-server'

@description('The location of the Managed Cluster resource.')
param location string = resourceGroup().location

@description('The size of the Virtual Machine.')
param agentVMSize string = 'd4ps_v6'

@description('The Kubernetes version of the Managed Cluster resource.')
param kubernetesVersion string = '1.29'

@description('DNS prefix for the public DNS name of the cluster.')
param dnsPrefix string = '${clusterName}${uniqueString(resourceGroup().id)}'

// Revise vm and count etc. to match eks config files
resource aksCluster 'Microsoft.ContainerService/managedClusters@2024-02-01' = {
  name: clusterName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    kubernetesVersion: kubernetesVersion
    dnsPrefix: dnsPrefix
    agentPoolProfiles: [
      {
        name: 'webgroup'
        osDiskSizeGB: 550
        count: 2
        vmSize: agentVMSize
        osType: 'Linux'
        nodeLabels: {
          nodegroup: 'web-group'
        }
        mode: 'System'
      }
      {
        name: 'workergroup'
        osDiskSizeGB: 400
        count: 1
        vmSize: agentVMSize
        osType: 'Linux'
        nodeLabels: {
          nodegroup: 'worker-group'
        }
        enableAutoScaling: true
        minCount: 0
        maxCount: 6
        mode: 'User'
      }
    ]
  }
}

output controlPlaneFQDN string = aksCluster.properties.fqdn
