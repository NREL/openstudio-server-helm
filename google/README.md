Below is a guide to help setup a Google Kubernetes Cluster using the gcloud cli utility. This guide is meant to provide steps to setup the cluster. Please refer to the [helm chart](/README.md) to install openstudio-server chart once the EKS cluster is up and running.

## Prerequisites

- Google Cloud Account with Kubernetes privileges
- Google gcloud CLI utility

## Install gcloud client

https://cloud.google.com/sdk/install
https://cloud.google.com/sdk/docs/downloads-interactive

## Use gcloud to login to your account.

`gcloud auth login`

## Create a project

\*Note - if already have one existing project you can use that one (see below)

`gcloud projects create openstudio-server`

## Set the project

`gcloud config set project openstudio-server`

## Create the cluster.

Below is an example that will create a Google Kubernetes cluster that has 3 nodes of instance type `n1-standard-4` with max nodes = 8. This cluster is set to autoscale up to this max node amount. You can change the instance type and min and max node setting to your use case. More info on [Google instance types](https://cloud.google.com/compute/docs/machine-types/)

```bash
    gcloud container clusters create openstudio-server \
      --zone us-west1-a \
      --disk-size=50 \
      --disk-type=pd-standard \
      --machine-type=n1-standard-4 \
      --num-nodes=3 \
      --enable-autoscaling \
      --max-nodes=8 \
      --min-nodes=3
```

## Create a cluster with separate node groups

Below are options for creating a Google Kubernetes cluster with two node groups: one for web-related pods and another for worker pods. This setup mimics the structure in the eks_config_small.yaml and eks_config_large.yaml files used for AWS EKS clusters.

### Option 1: Using individual gcloud commands

First, create the cluster with a default node pool (we'll delete this later):

```bash
gcloud container clusters create openstudio-server \
  --zone us-west1-a \
  --num-nodes=1 \
  --disk-size=50 \
  --disk-type=pd-standard
```

Next, create the web-node-group for web-related pods:

```bash
gcloud container node-pools create web-node-group \
  --cluster=openstudio-server \
  --zone=us-west1-a \
  --machine-type=n2-standard-32 \
  --disk-size=550 \
  --disk-type=pd-ssd \
  --num-nodes=1 \
  --enable-autoscaling \
  --min-nodes=0 \
  --max-nodes=2 \
  --node-labels=nodegroup=web-group
```

Then, create the worker-node-group for simulation worker pods:

```bash
gcloud container node-pools create worker-node-group \
  --cluster=openstudio-server \
  --zone=us-west1-a \
  --machine-type=c2-standard-60 \
  --disk-size=400 \
  --disk-type=pd-ssd \
  --num-nodes=1 \
  --enable-autoscaling \
  --min-nodes=0 \
  --max-nodes=50 \
  --node-labels=nodegroup=worker-group
```

Finally, delete the default node pool since we now have our specialized node groups:

```bash
gcloud container node-pools delete default-pool \
  --cluster=openstudio-server \
  --zone=us-west1-a
```

### Option 2: Using shell scripts

Unlike EKS, GKE doesn't have a direct equivalent to `eksctl create cluster -f config.yaml` for creating a complete cluster with multiple node pools in a single command. However, we've provided two shell scripts in this repository to automate the process.

Similar to the `eks_config_small.yaml` and `eks_config_large.yaml` files for EKS, we have two scripts for different cluster sizes:

#### Small Cluster Configuration

The script `create-gke-cluster-small.sh` creates a cluster with smaller node types suitable for development or testing:

- **Web Node Group**: 2x `n1-standard-4` instances (fixed at 2 nodes)
- **Worker Node Group**: 1x `n1-standard-4` instance (autoscaling from 0-6 nodes)

To use the script:

```bash
# Make sure the script is executable
chmod +x google/create-gke-cluster-small.sh

# Run the script
./google/create-gke-cluster-small.sh
```

#### Large Cluster Configuration

The script `create-gke-cluster-large.sh` creates a cluster with larger node types suitable for production workloads:

- **Web Node Group**: 1x `n2-standard-32` instance (autoscaling from 0-2 nodes)
- **Worker Node Group**: 1x `c2-standard-60` instance (autoscaling from 0-50 nodes)

To use the script:

```bash
# Make sure the script is executable
chmod +x google/create-gke-cluster-large.sh

# Run the script
./google/create-gke-cluster-large.sh
```

You can also customize either script by editing it to change parameters like machine types, disk sizes, or the number of nodes.

### Option 3: Using Terraform

For more complex deployments or infrastructure-as-code approaches, Terraform provides a robust way to create GKE clusters with multiple node pools in a declarative manner.

Create a file named `main.tf`:

```hcl
provider "google" {
  project = "your-project-id"
  region  = "us-west1"
  zone    = "us-west1-a"
}

resource "google_container_cluster" "primary" {
  name     = "openstudio-server"
  location = "us-west1-a"

  # We can't create a cluster with no node pool defined, but we want to only use
  # separately managed node pools. So we create the smallest possible default
  # node pool and immediately delete it.
  remove_default_node_pool = true
  initial_node_count       = 1
}

resource "google_container_node_pool" "web_nodes" {
  name       = "web-node-group"
  location   = "us-west1-a"
  cluster    = google_container_cluster.primary.name
  node_count = 1

  autoscaling {
    min_node_count = 0
    max_node_count = 2
  }

  node_config {
    machine_type = "n2-standard-32"
    disk_size_gb = 550
    disk_type    = "pd-ssd"

    labels = {
      nodegroup = "web-group"
    }

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]
  }
}

resource "google_container_node_pool" "worker_nodes" {
  name       = "worker-node-group"
  location   = "us-west1-a"
  cluster    = google_container_cluster.primary.name
  node_count = 1

  autoscaling {
    min_node_count = 0
    max_node_count = 50
  }

  node_config {
    machine_type = "c2-standard-60"
    disk_size_gb = 400
    disk_type    = "pd-ssd"

    labels = {
      nodegroup = "worker-group"
    }

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]
  }
}
```

To use Terraform:

```bash
# Initialize Terraform
terraform init

# Preview the changes
terraform plan

# Apply the changes
terraform apply
```

## Set credentials to use cluster

```bash
gcloud container clusters get-credentials openstudio-server --zone us-west1-a
```

The above cmd should return that cluster info.

e.g.,

```bash
NAME               LOCATION    MASTER_VERSION  MASTER_IP     MACHINE_TYPE   NODE_VERSION    NUM_NODES  STATUS
openstudio-server  us-west1-a  1.14.10-gke.27  35.230.92.87  n1-standard-4  1.14.10-gke.27  3          RUNNING
```

After deployment, retrieve the OpenStudio Server external endpoint with:

```bash
kubectl get svc ingress-load-balancer -n openstudio-server
```

Use the `EXTERNAL-IP` value in PAT under **Existing Server URL**.

## Delete cluster

When you are finished and you can simply delete the entire cluster.

```bash
gcloud container clusters delete openstudio-server --zone us-west1-a
```

## Idle cluster

Google allows you to keep the Kubernetes cluster up and running without having any node running. You can scale down the cluster size to 0 and then scale back up when you want to use the cluster again.

```bash
gcloud container clusters resize openstudio-server --num-nodes=0 --zone us-west1-a
```

Confirm cluster is now zero nodes

```bash
kubectl get nodes
```

Should show no nodes

```bash
kubectl get pods
```

Should show all pods in pending state

To scale back up the cluster simply resize the command back to the original min size.

```bash
gcloud container clusters resize openstudio-server --num-nodes=3 --zone us-west1-a
```

```bash
kubectl get nodes
```

Should show all nodes available

```bash
kubectl get pods
```

Should show all pods in running state.
