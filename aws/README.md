
Below is a guide to help provsion a AWS Kubernetes cluster. 

## Prerequisites

- AWS Account with EKS privileges
- AWS eksctl client 
- Helm client
- Kubectl client

### Install eksctl client
https://docs.aws.amazon.com/eks/latest/userguide/eksctl.html#installing-eksctl

### Install helm client
https://helm.sh/docs/intro/install/

### Install Kubectl client

https://kubernetes.io/docs/tasks/tools/install-kubectl/


### To create a simple cluster using eksctl

eksctl create cluster \
--name openstudio-server \
--version 1.14 \
--region us-west-2 \
--nodegroup-name standard-workers \
--node-type c5.xlarge \
--nodes 5 \
--nodes-min 1 \
--nodes-max 5 \
--ssh-access \
--ssh-public-key ~/.ssh/id_rsa.pub \
--managed

# more info here: 
https://docs.aws.amazon.com/eks/latest/userguide/create-cluster.html


# example output of what you should see

[ℹ]  eksctl version 0.13.0
[ℹ]  using region us-west-2
[ℹ]  setting availability zones to [us-west-2a us-west-2b us-west-2d]
[ℹ]  subnets for us-west-2a - public:192.168.0.0/19 private:192.168.96.0/19
[ℹ]  subnets for us-west-2b - public:192.168.32.0/19 private:192.168.128.0/19
[ℹ]  subnets for us-west-2d - public:192.168.64.0/19 private:192.168.160.0/19
[ℹ]  using SSH public key "~./ssh/id_rsa.pub" as "eksctl-openstudio-server-nodegroup-standard-workers-b3:7d:b1:20:da:5c:66:07:07:35:65:af:80:8a:f0:a0"
[ℹ]  using Kubernetes version 1.14
[ℹ]  creating EKS cluster "openstudio-server" in "us-west-2" region with managed nodes
[ℹ]  will create 2 separate CloudFormation stacks for cluster itself and the initial managed nodegroup
[ℹ]  if you encounter any issues, check CloudFormation console or try 'eksctl utils describe-stacks --region=us-west-2 --cluster=openstudio-server'
[ℹ]  CloudWatch logging will not be enabled for cluster "openstudio-server" in "us-west-2"
[ℹ]  you can enable it with 'eksctl utils update-cluster-logging --region=us-west-2 --cluster=openstudio-server'
[ℹ]  Kubernetes API endpoint access will use default of {publicAccess=true, privateAccess=false} for cluster "openstudio-server" in "us-west-2"
[ℹ]  2 sequential tasks: { create cluster control plane "openstudio-server", create managed nodegroup "standard-workers" }
[ℹ]  building cluster stack "eksctl-openstudio-server-cluster"
[ℹ]  deploying stack "eksctl-openstudio-server-cluster"
[ℹ]  building managed nodegroup stack "eksctl-openstudio-server-nodegroup-standard-workers"
[ℹ]  deploying stack "eksctl-openstudio-server-nodegroup-standard-workers"
[✔]  all EKS cluster resources for "openstudio-server" have been created
[✔]  saved kubeconfig as "/Users/tcoleman/.kube/config"
[ℹ]  nodegroup "standard-workers" has 3 node(s)
[ℹ]  node "ip-192-168-25-158.us-west-2.compute.internal" is ready
[ℹ]  node "ip-192-168-37-171.us-west-2.compute.internal" is ready
[ℹ]  node "ip-192-168-84-169.us-west-2.compute.internal" is ready
[ℹ]  waiting for at least 1 node(s) to become ready in "standard-workers"
[ℹ]  nodegroup "standard-workers" has 3 node(s)
[ℹ]  node "ip-192-168-25-158.us-west-2.compute.internal" is ready
[ℹ]  node "ip-192-168-37-171.us-west-2.compute.internal" is ready
[ℹ]  node "ip-192-168-84-169.us-west-2.compute.internal" is ready
[ℹ]  kubectl command should work with "/Users/tcoleman/.kube/config", try 'kubectl get nodes'
[✔]  EKS cluster "openstudio-server" in "us-west-2" region is ready


