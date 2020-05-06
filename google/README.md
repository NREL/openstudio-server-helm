Below is a guide to help setup a Google Kubernetes Cluster using the gcloud  cli utility. This guide is meant to provide steps to setup the cluster. Please refer to the [helm chart](/README.md) to install openstudio-server chart once the EKS cluster is up and running.  

## Prerequisites

- Google Cloud Account with Kubernetes privileges
- Google gcloud CLI utility 


## Install gcloud client
https://cloud.google.com/sdk/install
https://cloud.google.com/sdk/docs/downloads-interactive


## Use gcloud to login to your account. 
`$ gcloud auth login`


## Create a project

*Note - if already have one existing project you can use that one (see below)

`$ gcloud projects create openstudio-server`

## Set the project

`$ gcloud config set project openstudio-server`

## Create the cluster.  

Below is an example that will create an AWS EKS cluster that has 3 nodes of instance type `n1-standard-4`` with max nodes = 8. This cluster is set to autoscale up to this max node amount. You can change the instance type and min and max node setting to your use case.  More info on [Google instance types](https://cloud.google.com/compute/docs/machine-types/)

    $ gcloud container clusters create openstudio-server \
      --zone us-west1-a \
      --disk-size=50 \
      --disk-type=pd-standard \
      --machine-type=n1-standard-4 \
      --num-nodes=3 \
      --enable-autoscaling \
      --max-nodes=8 \
      --min-nodes=3

## Set credentials to use cluster

`$ gcloud container clusters get-credentials openstudio-server --zone us-west1-a`

The above cmd should return that cluster info. 

e.g. 

```NAME               LOCATION    MASTER_VERSION  MASTER_IP     MACHINE_TYPE   NODE_VERSION    NUM_NODES  STATUS
openstudio-server  us-west1-a  1.14.10-gke.27  35.230.92.87  n1-standard-4  1.14.10-gke.27  3          RUNNING
```

## Delete cluster

When you are finished and you can simply delete the entire cluster. 

 ```$ gcloud container clusters delete openstudio-server --zone us-west1-a```


## Idle cluster

Google allows you to keep the Kubernetes cluster up and running without having any node running. You can scale down the cluster size to 0 and then scale back up when you want to use the cluster again. 

`$ gcloud container clusters resize openstudio-server --num-nodes=0 --zone us-west1-a`

Confirm cluster is now zero nodes

`$ kubectl get nodes`  
Should show no nodes  
`$ kubectl get po`  
Should show all pods in pending state

To scale back up the cluster simply resize the command back to the original min size. 

`$ gcloud container clusters resize openstudio-server --num-nodes=3 --zone us-west1-a`  

`$ kubectl get nodes`  
Should show all nodes available  
`$  kubectl get po`  
Should show all pods in running state. 















