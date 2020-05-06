# OpenStudio Server

[OpenStudio Server](https://github.com/NREL/OpenStudio-server) is a Kubernetes deployable instance using helm charts which allows for large-scale parametric analyses of building energy models using the OpenStudio SDK in the form of OpenStudio measures.

## Introduction

This helm chart installs a OpenStudio-server instance (https://github.com/NREL/OpenStudio-server/) deployment on a [Kubernetes](http://kubernetes.io) cluster using the [Helm](https://helm.sh) package manager. 
You can interface with the OpenStudio-server cluster using the [Parametric Analysis Tool](https://github.com/NREL/OpenStudio-PAT), which is part of the OpenStudio collection of software tools.

## Prerequisites

- Kubernetes 1.3+ cluster.  Please refer to cluster setup instructions for [google](/google/README.md) or [aws](/aws/README.md) for information on how to provision a cluster. 
- [helm client](https://helm.sh/docs/intro/install/)
- [kubectl client](https://kubernetes.io/docs/tasks/tools/install-kubectl/)

## Installing the Chart

To install the helm chart with the chart name `openstudio-server`, you can run the following command in the root directory of this repo. This assumes you already have a Kubernetes cluster up and running. If you do not, please refer to [google](/google/README.md) or [aws](/aws/README.md) in this repo.  


For Google  
`$ helm install openstudio-server ./openstudio-server --set provider.name=google`

For Amazon  
`$ helm install openstudio-server ./openstudio-server --set provider.name=aws`

## Uninstalling the Chart

To uninstall/delete the `openstudio-server` helm chart:

`$ helm delete openstudio-server`

The command removes all the Kubernetes components associated with the chart and deletes the release *including* persistent volumes. See more about persistent volumes below. 

## Configuration

The following table lists the configurable parameters of the OpenStudio-server chart and their default values. You can override any of these values by specify each parameter using the `--set key=value[,key=value]` argument to `helm install`. For example, to change the data storage for NFS which stores the data points to 300GB you would run this install command:

For Google  
`$ helm install openstudio-server ./openstudio-server --set provider.name=google --set nfs-server-provisioner.persistence.size=300GB`

For Amazon  
`$ helm install openstudio-server ./openstudio-server --set provider.name=aws --set nfs-server-provisioner.persistence.size=300GB`


Parameter | Description | Default
--------- | ----------- | -------
nfs-server-provisioner.persistence.size | Size of the volume for storing the data point results | 200GB |
db.persistence.size | Size of the volume for MongoDB | 200GB |
cluster.name | Kubernetes AWS or Google cluster name. If you change the default name you need to set this name here otherwise AWS auto-scaling will not work correctly | openstudio-server |
worker_hpa.minReplicas | Worker pods that run the simulations | 1 |
worker_hpa.maxReplicas | Maximum Worker pods that run the simulations | 20 |
worker_hpa.targetCPUUtilizationPercentage | When aggregate CPU % of worker pods exceed threshold begin scaling. | 50 |


## Accessing OpenStudio Server

First make sure all the Kubernetes pods are up in running. You can confirm this by running:

`$ kubectl get po`  

example output of all pods running: 

```
NAME                                                       READY   STATUS    RESTARTS   AGE
db-679f8c764c-52c2r                                        1/1     Running   0          109s
openstudio-server-nfs-server-provisioner-d7b798757-bt4p7   1/1     Running   0          109s
redis-7fd955fd84-2l4t4                                     1/1     Running   0          109s
rserve-8699d8d9f6-zwkmj                                    1/1     Running   0          109s
web-5b474c569d-wddhr                                       1/1     Running   0          109s
web-background-84c868cd9d-24sbl                            1/1     Running   0          109s
worker-cf755cccf-9twqw                                     1/1     Running   0          109s
```

Once the cluster is up and running, you can then find the external IP or DN to access OpenStudio server. For example, on AWS, this is the external name. 

AWS
```
$ kubectl get svc  ingress-load-balancer
NAME                    TYPE           CLUSTER-IP      EXTERNAL-IP                                                               PORT(S)                      AGE
ingress-load-balancer   LoadBalancer   10.100.91.255   a0a4014d98f0211ea91cb06528280f48-1900622776.us-west-2.elb.amazonaws.com   80:31837/TCP,443:32347/TCP   3m51s
```
Google
```
$ kubectl get svc  ingress-load-balancer
NAME                    TYPE           CLUSTER-IP      EXTERNAL-IP   PORT(S)                      AGE
ingress-load-balancer   LoadBalancer   10.55.246.197   35.247.75.9   80:32613/TCP,443:31562/TCP   35m
```

You will then use this EXTERNAL-IP to use with PAT to connect to an exisiting cloud server. In this example, you would enter http://a0a4014d98f0211ea91cb06528280f48-1900622776.us-west-2.elb.amazonaws.com in PAT under Exisiting Server URL in PAT.  For Google, using the example above, it would be http://35.247.75.9 


## Persistent Volumes

This helm chart provisions persistent storage for the Database (MongoDB) and the NFS server (storage for data results). These will persist throughout the life of the helm chart while it's running. It will **NOT** persist if you delete the helm chart. The volumes will be deleted along with it.  

While it's possible to change the storage to use `Retain` vs `Delete`, the helm chart will need to reconfigured to allow to attach to existing volumes. This will be worked on as an enhancement for a future release.  

## Auto Scaling

The worker pods are configured to auto-scale based on CPU threshold (default 50%). Once the aggregate CPU for all worker pods exceed the defined threshold (in this case 50%), the Kubernetes engine will start adding additional worker pods up to the maximum specified. This is also dependent on how the Kuebernetes cluster was configured as additional VM node instances will also be added. Please refer to the notes on [aws](/aws/README.md) and [google](/google/README.md) when setting up the cluster and note the instance type and maximum nodes specified.  

Once the aggregate CPU of the workers drop below 50%, the Kubernetes engine will start removing worker pod instances. There is a [prestop hook](https://kubernetes.io/docs/concepts/containers/container-lifecycle-hooks/) configured in the worker pod to ensure that if a openstudio job is still active it will not terminate the pod until it is finished.  















