Below is a guide to help provision a Google Kubernetes cluster. 

## Prerequisites

- Google Cloud Account with Kubernetes privileges
- Google gcloud client 
- Helm client
- Kubectl client

### Install gcloud client
https://cloud.google.com/sdk/install
https://cloud.google.com/sdk/docs/downloads-interactive

### Install helm client
https://helm.sh/docs/intro/install/

### Install Kubectl client

https://kubernetes.io/docs/tasks/tools/install-kubectl/

## To create a simple cluster using gcloud

Use gcloud to login. 
```$ gcloud auth login```

create a project

```$ gcloud projects create openstudio-server```

Set project

```$ gcloud config set project openstudio-server```

    $ gcloud container clusters create openstudio-server \
      --zone us-west1-a \
      --disk-size=50 \
      --disk-type=pd-standard \
      --machine-type=n1-standard-4 \
      --num-nodes=3 \
      --enable-autoscaling \
      --max-nodes=3 \
      --min-nodes=3```

set kubectl to use cluster

```$ gcloud container clusters get-credentials openstudio-server --zone us-west1-a```

delete cluster

 ```$ gcloud container clusters delete openstudio-server --zone us-west1-a```






