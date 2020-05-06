
Below is a guide to help setup a AWS Elastic Kubernetes Cluster (EKS) cluster using the AWS eksclt cli utility. This guide is meant to provide steps to setup the EKS cluster. Please refer to the [helm chart](/README.md) to install openstudio-server chart once the EKS cluster is up and running.  

## Prerequisites

- AWS Account with EKS privileges
- AWS [eksctl client](https://docs.aws.amazon.com/eks/latest/userguide/eksctl)

## Install eksctl client
https://docs.aws.amazon.com/eks/latest/userguide/eksctl.html#installing-eksctl


## Create a cluster using eksctl

eksctl will need access to AWS. You can provide access via ENV variables (example below). More advanced info on eksctl can be found here: https://eksctl.io/

```
$ export AWS_ACCESS_KEY_ID="YOUR_AWS_ACCESS_KEY_ID"
$ export AWS_SECRET_ACCESS_KEY="YOUR_AWS_SECRET_ACCESS_KEY"
$ export AWS_DEFAULT_REGION="YOUR_AWS_DEFAULT_REGION"
```
Below is an example that will create an AWS EKS cluster that has 3 nodes of instance type `t2.xlarge` with max nodes = 8. This cluster is set to autoscale up to this max node amount. You can change the instance type and min and max node setting to your use case.  More info on [AWS instance types](https://aws.amazon.com/ec2/instance-types/)

```
$ eksctl create cluster \
    --name openstudio-server \
    --version 1.14 \
    --region us-west-2 \
    --nodegroup-name standard-workers \
    --node-type t2.xlarge\
    --nodes 3 \
    --nodes-min 3 \
    --nodes-max 8 \
    --asg-access \
    --ssh-access \
    --ssh-public-key ~/.ssh/id_rsa.pub \
    --managed
```

## Delete the cluster using eksctl

To delete the cluster you just need to specify the name of the cluster. 

`$ eksctl delete cluster --name openstudio-server`

This is an example of the output you should see when you delete the cluster: 

```
[ℹ]  eksctl version 0.18.0
[ℹ]  using region us-west-2
[ℹ]  deleting EKS cluster "openstudio-server"
[ℹ]  deleted 0 Fargate profile(s)
[✔]  kubeconfig has been updated
[ℹ]  cleaning up LoadBalancer services
[ℹ]  2 sequential tasks: { delete nodegroup "standard-workers", delete cluster control plane "openstudio-server" [async] }
[ℹ]  will delete stack "eksctl-openstudio-server-nodegroup-standard-workers"
[ℹ]  waiting for stack "eksctl-openstudio-server-nodegroup-standard-workers" to get deleted
[ℹ]  will delete stack "eksctl-openstudio-server-cluster"
[✔]  all cluster resources were deleted
```

It's always good idea to verify the cluster has been deleted. 

`$ eksctl get cluster`

This cmd should return no clusters. You can also use the web console in your AWS account to verify as well. 











