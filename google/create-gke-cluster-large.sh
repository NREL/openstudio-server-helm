#!/bin/bash

# create-gke-cluster-large.sh
# Script to create a GKE cluster with larger node types suitable for production or large workloads

# Set variables
CLUSTER_NAME="openstudio-server"
ZONE="us-west1-a"

# Create the cluster with minimal default node pool
echo "Creating cluster $CLUSTER_NAME (large configuration)..."
gcloud container clusters create $CLUSTER_NAME \
  --zone $ZONE \
  --num-nodes=1 \
  --disk-size=50 \
  --disk-type=pd-standard

# Create web node pool - larger instance for production workloads
echo "Creating web node pool..."
gcloud container node-pools create web-node-group \
  --cluster=$CLUSTER_NAME \
  --zone=$ZONE \
  --machine-type=n2-standard-32 \
  --disk-size=550 \
  --disk-type=pd-ssd \
  --num-nodes=1 \
  --enable-autoscaling \
  --min-nodes=0 \
  --max-nodes=2 \
  --node-labels=nodegroup=web-group

# Create worker node pool - larger instance for production workloads
echo "Creating worker node pool..."
gcloud container node-pools create worker-node-group \
  --cluster=$CLUSTER_NAME \
  --zone=$ZONE \
  --machine-type=c2-standard-60 \
  --disk-size=400 \
  --disk-type=pd-ssd \
  --num-nodes=1 \
  --enable-autoscaling \
  --min-nodes=0 \
  --max-nodes=50 \
  --node-labels=nodegroup=worker-group

# Delete default node pool
echo "Deleting default node pool..."
gcloud container node-pools delete default-pool \
  --cluster=$CLUSTER_NAME \
  --zone=$ZONE --quiet

echo "Large cluster setup complete!"
echo "To connect to this cluster, run: gcloud container clusters get-credentials $CLUSTER_NAME --zone $ZONE"
