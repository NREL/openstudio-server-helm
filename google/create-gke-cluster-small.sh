#!/bin/bash

# create-gke-cluster-small.sh
# Script to create a GKE cluster with smaller node types suitable for development or smaller workloads

# Set variables
CLUSTER_NAME="openstudio-server"
ZONE="us-west1-a"

# Create the cluster with minimal default node pool
echo "Creating cluster $CLUSTER_NAME (small configuration)..."
gcloud container clusters create $CLUSTER_NAME \
  --zone $ZONE \
  --num-nodes=1 \
  --disk-size=50 \
  --disk-type=pd-standard

# Create web node pool - smaller instance for development/testing
echo "Creating web node pool..."
gcloud container node-pools create web-node-group \
  --cluster=$CLUSTER_NAME \
  --zone=$ZONE \
  --machine-type=n1-standard-4 \
  --disk-size=150 \
  --disk-type=pd-ssd \
  --num-nodes=2 \
  --enable-autoscaling \
  --min-nodes=2 \
  --max-nodes=2 \
  --node-labels=nodegroup=web-group

# Create worker node pool - smaller instance for development/testing
echo "Creating worker node pool..."
gcloud container node-pools create worker-node-group \
  --cluster=$CLUSTER_NAME \
  --zone=$ZONE \
  --machine-type=n1-standard-4 \
  --disk-size=200 \
  --disk-type=pd-ssd \
  --num-nodes=1 \
  --enable-autoscaling \
  --min-nodes=0 \
  --max-nodes=6 \
  --node-labels=nodegroup=worker-group

# Delete default node pool
echo "Deleting default node pool..."
gcloud container node-pools delete default-pool \
  --cluster=$CLUSTER_NAME \
  --zone=$ZONE --quiet

echo "Small cluster setup complete!"
echo "To connect to this cluster, run: gcloud container clusters get-credentials $CLUSTER_NAME --zone $ZONE"
