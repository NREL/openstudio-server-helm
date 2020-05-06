# OpenStudio Server

[OpenStudio Server](https://github.com/NREL/OpenStudio-server) is a Kubernetes deployable instance using helm charts which allows for large-scale parametric analyses of building energy models using the OpenStudio SDK in the form of OpenStudio measures.

## Introduction

This helm chart installs a OpenStudio-server instance (https://github.com/NREL/OpenStudio-server/) deployment on a [Kubernetes](http://kubernetes.io) cluster using the [Helm](https://helm.sh) package manager. 
You can interface with the OpenStudio-server cluster using the [Parametric Analysis Tool](https://github.com/NREL/OpenStudio-PAT), which is part of the OpenStudio collection of software tools, or use OpenStudio CLI utility (TODO).

## Prerequisites

- Kubernetes 1.3+ cluster.  Please refer to cluster setup instructions for [google](/google/README.md) or [aws](/aws/README.md) for information on how to provision a cluster. 
- [helm client](https://helm.sh/docs/intro/install/)
- [kubectl client](https://kubernetes.io/docs/tasks/tools/install-kubectl/)

## Installing the Chart

To install the helm chart with the application name `openstudio-server` you can run the following command in the root directory of this repo. 
This example below sets the `provider.name=google` If you are running aws you will want to run it using `provider.name=aws`

For Google  
`$ helm install openstudio-server --debug ./openstudio-server --set provider.name=google`

For Amazon
`$ helm install openstudio-server --debug ./openstudio-server --set provider.name=aws`

## Uninstalling the Chart

To uninstall/delete the `openstudio-server` helm chart:

```console
$ helm delete openstudio-server --debug
```

The command removes all the Kubernetes components associated with the chart and deletes the release.

## Configuration

The following table lists the configurable parameters of the OpenStudio-server chart and their default values.

Parameter | Description | Default
--------- | ----------- | -------
nfs-server-provisioner.persistence.size | Size of the volume for storing the data point results | 200GB |
db.persistence.size | Size of the volume for MongoDB | 200GB |
cluster.name | Kubernetes AWS or Google cluster name. If you change the default name you need to set this name here otherwise AWS auto-scalling will not work correctly | openstudio-server |
worker_hpa.minReplicas | Worker pods that run the simulations | 1 |
worker_hpa.maxReplicas | Maxium Worker pods that run the simulations | 20 |
worker_hpa.targetCPUUtilizationPercentage | When aggregate CPU % of worker pods exceed threshold begin scallling. | 50 |



Specify each parameter using the `--set key=value[,key=value]` argument to `helm install`. For example,

```console
$ helm install ./openstudio-server --name my-release \
    --set fs-server-provisioner.persistence.size=300GB
```

## Accessing OpenStudio Server

First make sure all the kubenetes pods are up in running. You can confirm this by running:

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

Once the cluster is up and running you can then find the external IP or DN to access OpenStudio server. For example, on AWS this is the external name. 

AWS
```
$ kubectl get svc  ingress-load-balancer
NAME                    TYPE           CLUSTER-IP      EXTERNAL-IP                                                               PORT(S)                      AGE
ingress-load-balancer   LoadBalancer   10.100.91.255   a0a4014d98f0211ea91cb06528280f48-1900622776.us-west-2.elb.amazonaws.com   80:31837/TCP,443:32347/TCP   3m51s
```
Google
$ kubectl get svc  ingress-load-balancer
NAME                    TYPE           CLUSTER-IP      EXTERNAL-IP   PORT(S)                      AGE
ingress-load-balancer   LoadBalancer   10.55.246.197   35.247.75.9   80:32613/TCP,443:31562/TCP   35m

You will then use this EXTERNAL-IP to use with PAT to connect to an exisiting cloud server. In this example, you would enter http://a0a4014d98f0211ea91cb06528280f48-1900622776.us-west-2.elb.amazonaws.com in PAT under Exisiting Server URL.  For Google, using the example above, it would be http://35.247.75.9 


#### Persistent Volumes

This helm chart provisiones presientet storage for the Database (MongoDB) and the NFS server (storage for data results). These will persist throughout the life of the helm chart while it's running. It will **NOT** persist if you delete the helm chart. The volumes will be deleted along with it.  

While it's possible to change the storage to use `Retain` vs `Delete`, the helm chart will need to reconfigured to allow to attach to exisiting volumes. This will be worked on as an enahcmenet to future release.  

#### Auto Scaling

The worker pods are configured to auto-scale based on CPU threshold (currently 50%). Once the aggregate CPU for worker pods exceeed the threshold, Kubernetes engine will start adding addtional worker pods up to the maximum specified. This is also dependent on how the Kuebernetes cluster was configured. Please refer to the notes on Google 

Please refer to cluster setup instructions for [google](/google/README.md) or [aws](/aws/README.md) for information on how to provision a cluster that is able to autoscale. The example provided are set to autoscale up to a max node.  

Once the aggregate CPU of the workers drop below 50%, the Kubernetes engine will start removing worker pod instances. There is a prestop hook configured in the worker pod to ensure that if a openstudio job is still active, it will not terminate the pod until that is finished.  















