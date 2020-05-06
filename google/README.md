Below is a guide to help provision a Google Kubernetes cluster. 

## Prerequisites

- Google Cloud Account with Kubernetes privileges
- Google gcloud CLI utility 
- Helm CLI utility 
- Kubectl client

#### Install gcloud client
https://cloud.google.com/sdk/install
https://cloud.google.com/sdk/docs/downloads-interactive

#### Install helm client
https://helm.sh/docs/intro/install/

#### Install Kubectl client

https://kubernetes.io/docs/tasks/tools/install-kubectl/


## Steps to create a kubernetes cluster using gcloud

#### Use gcloud to login. 
```$ gcloud auth login```

#### Create a project if you don't already have one or use existing project

```$ gcloud projects create openstudio-server```

#### Set project

```$ gcloud config set project openstudio-server```

#### Create the cluster.  

Below is just an example of creating a cluster. This example uses a minimum of 3x `n1-standard-4` and can autoscale to 8x instance giving a 
a min resource of (3x4) = 12 vCPU and (3x15) 45GB Memory and maximum (8x4) = 48 vCPU and (8x15) = 120 GB Memory

Here is a full list on instance that can be configured. You can use this to customize the instance type and set the min and max to the proper range. 

https://cloud.google.com/compute/docs/machine-types 

    $ gcloud container clusters create openstudio-server \
      --zone us-west1-a \
      --disk-size=50 \
      --disk-type=pd-standard \
      --machine-type=n1-standard-4 \
      --num-nodes=3 \
      --enable-autoscaling \
      --max-nodes=8 \
      --min-nodes=3

#### set kubectl to use cluster

```$ gcloud container clusters get-credentials openstudio-server --zone us-west1-a```

The above cmd should return that cluster info. 

e.g. 

```NAME               LOCATION    MASTER_VERSION  MASTER_IP     MACHINE_TYPE   NODE_VERSION    NUM_NODES  STATUS
openstudio-server  us-west1-a  1.14.10-gke.27  35.230.92.87  n1-standard-4  1.14.10-gke.27  3          RUNNING
```

#### confirm cluster is up 

```$ kubectl get nodes -o wide```

Running the above command you should see the minimum number of nodes running in the cluster.  Once you confirm that the nodes are running, you can now launch the helm chart in this repo. 

Please refer to [Installing the Chart](/README.md#Installing) to launch OpenStudio-server


#### delete cluster

When you are finished and you can simply delete the entire cluster. 

 ```$ gcloud container clusters delete openstudio-server --zone us-west1-a```


#### idle cluster

If you want to keep the cluster up and running but have very little overhead expenses, you can scale down
the number of nodes to 0. Google cloud allows you to have a 0 node pool.  This would be useful for certain situtations.  

```gcloud container clusters resize openstudio-server --num-nodes=0 --zone us-west1-a```

Confirm cluster is now zero nodes

`kubectl get nodes`
Should show no nodes
`kubectl get po`
Should show all pods in pending state

To scale back up the cluster simply resize the command back to the orginal min size. 

```gcloud container clusters resize openstudio-server --num-nodes=3 --zone us-west1-a```

`kubectl get nodes`
Should show all nodes available
`kubectl get po`
Should show all pods in running state. 















