
Below is a guide to help setup a AWS Elastic Kubernetes Cluster (EKS) cluster using the AWS eksclt cli utility. This guide is meant to provide steps to setup the EKS cluster. Please refer to the [helm chart](/README.md) to install openstudio-server chart once the EKS cluster is up and running.  

## Prerequisites

- AWS Account with EKS privileges
- AWS [eksctl client](https://docs.aws.amazon.com/eks/latest/userguide/eksctl) (v0.34.0 or higher)

## Install eksctl client
https://docs.aws.amazon.com/eks/latest/userguide/eksctl.html#installing-eksctl (0.34.0 or higher)


## Create a cluster using eksctl

eksctl will need access to AWS. You can provide access by setting ENV variables in your shell before running the cli (example below). More advanced info on eksctl can be found here: https://eksctl.io/

```bash
export AWS_ACCESS_KEY_ID="YOUR_AWS_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="YOUR_AWS_SECRET_ACCESS_KEY"
export AWS_DEFAULT_REGION="YOUR_AWS_DEFAULT_REGION"
```

Below is an example that will create an AWS EKS cluster that has 3 nodes of instance type `t2.xlarge` with max nodes = 8. This cluster is set to autoscale up to this max node amount. You can change the instance type and min and max node setting to your use case.  More info on [AWS instance types](https://aws.amazon.com/ec2/instance-types/)

```bash
eksctl create cluster \
    --name openstudio-server \
    --version 1.22 \
    --region us-west-2 \
    --nodegroup-name standard-workers \
    --node-type t2.xlarge\
    --nodes 3 \
    --nodes-min 3 \
    --nodes-max 8 \
    --asg-access \
    --ssh-access \
    --ssh-public-key ~/.ssh/id_rsa.pub \
    --zones=us-west-2a,us-west-2b,us-west-2d \
    --managed \
    --tags environment=production
```

This is an example of the output you should see when you create the cluster: 

```bash
[ℹ]  eksctl version 0.34.0
[ℹ]  using region us-west-2
[ℹ]  setting availability zones to [us-west-2a us-west-2d us-west-2c]
[ℹ]  subnets for us-west-2a - public:192.168.0.0/19 private:192.168.96.0/19
[ℹ]  subnets for us-west-2d - public:192.168.32.0/19 private:192.168.128.0/19
[ℹ]  subnets for us-west-2c - public:192.168.64.0/19 private:192.168.160.0/19
[ℹ]  using SSH public key "/Users/tijcolem/.ssh/id_rsa.pub" as "eksctl-openstudio-server-nodegroup-standard-workers-8d:9e:ea:30:c1:55:57:67:3a:0e:f8:73:68:79:92:a9" 
[ℹ]  using Kubernetes version 1.18
[ℹ]  creating EKS cluster "openstudio-server" in "us-west-2" region with managed nodes
[ℹ]  will create 2 separate CloudFormation stacks for cluster itself and the initial managed nodegroup
[ℹ]  if you encounter any issues, check CloudFormation console or try 'eksctl utils describe-stacks --region=us-west-2 --cluster=openstudio-server'
[ℹ]  CloudWatch logging will not be enabled for cluster "openstudio-server" in "us-west-2"
[ℹ]  you can enable it with 'eksctl utils update-cluster-logging --enable-types={SPECIFY-YOUR-LOG-TYPES-HERE (e.g. all)} --region=us-west-2 --cluster=openstudio-server'
[ℹ]  Kubernetes API endpoint access will use default of {publicAccess=true, privateAccess=false} for cluster "openstudio-server" in "us-west-2"
[ℹ]  2 sequential tasks: { create cluster control plane "openstudio-server", 3 sequential sub-tasks: { no tasks, create addons, create managed nodegroup "standard-workers" } }
[ℹ]  building cluster stack "eksctl-openstudio-server-cluster"
[ℹ]  deploying stack "eksctl-openstudio-server-cluster"

[ℹ]  building managed nodegroup stack "eksctl-openstudio-server-nodegroup-standard-workers"
[ℹ]  deploying stack "eksctl-openstudio-server-nodegroup-standard-workers"
[ℹ]  waiting for the control plane availability...
[✔]  saved kubeconfig as "/Users/tijcolem/.kube/config"
[ℹ]  no tasks
[✔]  all EKS cluster resources for "openstudio-server" have been created
[ℹ]  nodegroup "standard-workers" has 3 node(s)
[ℹ]  node "ip-192-168-1-231.us-west-2.compute.internal" is ready
[ℹ]  node "ip-192-168-2-125.us-west-2.compute.internal" is ready
[ℹ]  node "ip-192-168-81-118.us-west-2.compute.internal" is ready
[ℹ]  waiting for at least 3 node(s) to become ready in "standard-workers"
[ℹ]  nodegroup "standard-workers" has 3 node(s)
[ℹ]  node "ip-192-168-1-231.us-west-2.compute.internal" is ready
[ℹ]  node "ip-192-168-2-125.us-west-2.compute.internal" is ready
[ℹ]  node "ip-192-168-81-118.us-west-2.compute.internal" is ready
[ℹ]  kubectl command should work with "/Users/tijcolem/.kube/config", try 'kubectl get nodes'
[✔]  EKS cluster "openstudio-server" in "us-west-2" region is ready
```

## Connecting to your cluster using kubectl

Once eksctl is done setting up the cluster, it will automatically setup the connection by creating a `~/.kube/config` file so you and can begin using helm and kubectl cli tools to communicate to the cluster.  occasionally, you need to run generate this config manually. If you are not able to run `kubectl get nodes` you can re-run the kube config setup by running `aws eks update-kubeconfig --name openstudio-server`  Change the `--name` to match the cluster name if different from the example.  

## Delete the cluster using eksctl

To delete the cluster you just need to specify the name of the cluster. 

`eksctl delete cluster --name openstudio-server`

This is an example of the output you should see when you delete the cluster: 

```bash
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

`eksctl get cluster`

This cmd should return no clusters. You can also use the web console in your AWS account to verify as well. 
