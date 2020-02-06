
# Install gcloud  

https://cloud.google.com/sdk/install
https://cloud.google.com/sdk/docs/downloads-interactive


# Login using gcloud

gcloud auth login
Your browser has been opened to visit:

# Create a project

gcloud projects create openstudio-server

# List projects

gcloud projects list

# Set project

gcloud config set project openstudio-server

# See machine types
gcloud compute machine-types list

gcloud container clusters create example-cluster \
      --zone us-west1-a \
      --additional-zones us-west1-b,us-west1-c \
      --disk-size=50 \
      --disk-type=pd-standard \
      --machine-type=n1-standard-4 \
      --num-nodes=2 \
      --enable-autoscaling \
      --max-nodes=2 \
      --min-nodes=2 

# Set kubectl

gcloud container clusters get-credentials example-cluster --zone us-west1-a

# NREL users will need to be on developer network or guest wireless 
