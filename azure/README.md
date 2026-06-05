Below is a guide to help setup a Microsoft Azure Kubernetes Cluster (AKS) using the azure cli utility. This guide is meant to provide steps to setup the cluster. Please refer to the [helm chart](/README.md) to install openstudio-server chart once the AKS is up and running.

## Prerequisites

- Microsoft Azure Account with Kubernetes privileges
- Microsoft Azure CLI utility `az`

## Install Azure cli client

https://docs.microsoft.com/en-us/cli/azure/install-azure-cli

## Define environment variables

```bash
export MY_RESOURCE_GROUP_NAME="openstudio-server"
export REGION="westus2"
export MY_AKS_CLUSTER_NAME="openstudio-server"
```

## Use az to login to your account.

```bash
az login
```

This will allow you to login to your Azure account. If your using only a terminal w/o a web browser, you can use altertative ways to use the cli utility to login. Please refer to the [login instructions](https://docs.microsoft.com/en-us/cli/azure/reference-index?view=azure-cli-latest#az_login)

## Create a resource group

Create a resource group and specifiy a data center location. The example below uses westus2 region.

```bash
az group create --name $MY_RESOURCE_GROUP_NAME --location $REGION
```

## Create the cluster. This example will create a cluster with 2 nodes of instance type Standard_DS2_v2 with max nodes = 6. This cluster is set to autoscale up to this max node amount. Vary the kubernetes version to your needs.

```bash
az deployment group create \
  --resource-group $MY_RESOURCE_GROUP_NAME \
  --template-file aks_config.bicep \
  --parameters clusterName=$MY_AKS_CLUSTER_NAME kubernetesVersion=1.29 \
```

## For large scale analysis, create the cluster using these parameters.

```bash
az deployment group create \
  --resource-group $MY_RESOURCE_GROUP_NAME \
  --template-file aks_config.bicep \
  --parameters clusterName=$MY_AKS_CLUSTER_NAME agentVMSize=D32ps_v6 kubernetesVersion=1.29 \
```

## Set credentials to use cluster.

```bash
az aks get-credentials --resource-group $MY_RESOURCE_GROUP_NAME --name $MY_AKS_CLUSTER_NAME
```

The above command creates the config in ~/.kube/config which is needed to use the `kubectl` cli to interface with the cluster. Once this is ran, confirm that you are connected and able to interface with the cluster by running the following.

```bash
kubectl get nodes
```

You should see similar output to this.

```bash
NAME                                STATUS   ROLES   AGE   VERSION
aks-nodepool1-23944537-vmss000000   Ready    agent   12m   v1.18.14
aks-nodepool1-23944537-vmss000001   Ready    agent   12m   v1.18.14
aks-nodepool1-23944537-vmss000002   Ready    agent   12m   v1.18.14
```

The cluster is now ready to deploy the helm chart. Please refer to the helm [README.md](../README.md) to deploy the openstudio-server helm chart.

After deployment, retrieve the OpenStudio Server external endpoint with:

```bash
kubectl get svc ingress-load-balancer -n openstudio-server
```

Use the `EXTERNAL-IP` value in PAT under **Existing Server URL**.

## Delete cluster

When you are finished and you can simply delete the entire cluster.

```bash
az aks delete --resource-group openstudio-server --name openstudio-server
```

## Delete resource group

```bash
az group delete --resource-group openstudio-server
```

## Idle cluster

TODO. Determine if Azure allows the cluster to be zero size nodes like Google.
