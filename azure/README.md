Below is a guide to help setup a Microsoft Azure Kubernetes Cluster (AKS) using the azure cli utility. This guide is meant to provide steps to setup the cluster. Please refer to the [helm chart](/README.md) to install openstudio-server chart once the AKS is up and running.  

## Prerequisites

- Microsoft Azure Account with Kubernetes privileges
- Microsoft Azure `az` CLI utility 

## Install Azure cli client
https://docs.microsoft.com/en-us/cli/azure/install-azure-cli


## Use az to login to your account. 
`az login`
This will allow you to login to your Azure account using a web browser, If your using a headless setup and only terminal, you can use altertative way to use the cli utility to login. Please refer to the [login instructions](https://docs.microsoft.com/en-us/cli/azure/reference-index?view=azure-cli-latest#az_login)

## Create a resource group

Create a resource group and specifiy a data center location. 

`az group create --name openstudio-server --location westus2`


## Create the cluster 


    az aks create --resource-group openstudio-server \
    --name openstudio-server \
    --kubernetes-version 1.18.14 \
    --node-count 3 \
    --node-vm-size Standard_D4_v4 \
    --enable-cluster-autoscaler \
    --min-count 3 \
    --max-count 6 \
    --ssh-key-value  ~/.ssh/id_rsa.pub 

## Set credentials to use cluster

`az aks install-cli`
`az aks get-credentials --resource-group openstudio-server --name openstudio-server`

## Delete cluster

When you are finished and you can simply delete the entire cluster. 

 `az aks delete --resource-group openstudio-server --name openstudio-server`

## Delete resource group 

`az group delete --resource-group openstudio-server`


## Idle cluster

TODO. Determine if Azure allows the cluster to be zero size nodes like Google does. 

















