# OpenStudio Server

[OpenStudio Server](https://github.com/NREL/OpenStudio-server) is a Kubernetes deployable instance using helm charts which allows for large-scale parametric analyses of building energy models using the OpenStudio SDK in the form of OpenStudio measures.

## Introduction

This helm chart installs a OpenStudio-server instance (https://github.com/NREL/OpenStudio-server/) deployment on a [Kubernetes](http://kubernetes.io) cluster using the [Helm](https://helm.sh) package manager.
You can interface with the OpenStudio-server cluster using the [Parametric Analysis Tool](https://github.com/NREL/OpenStudio-PAT), which is part of the OpenStudio collection of software tools.

Note that this repository has both information for small and large workloads in the cloud. Refer to the Large Workload section below and in the [aws README](/aws/README.md).

## Prerequisites

- Kubernetes 1.27+ cluster. Please refer to cluster setup instructions for [google](/google/README.md) or [aws](/aws/README.md) for information on how to provision a cluster.
- [helm client](https://helm.sh/docs/intro/install/) (v3.12.0 or higher)
- [kubectl client](https://kubernetes.io/docs/tasks/tools/install-kubectl/) (v1.27.0 or higher)

## Installing the Chart

To install the helm chart with the chart name `openstudio-server`, you can run the following command in the root directory of this repo. This assumes you already have a Kubernetes cluster up and running. If you do not, please refer to [google](/google/README.md) or [aws](/aws/README.md) in this repo.

### For Google

```bash
helm install openstudio-server ./openstudio-server --set provider.name=google
```

### For Amazon

```bash
helm install openstudio-server ./openstudio-server --set provider.name=aws
```

### For Azure

```bash
helm install openstudio-server ./openstudio-server --set provider.name=azure
```

### For OpenStack

```bash
helm install openstudio-server ./openstudio-server --set provider.name=openstack
```

## Supported Cloud Providers

The Helm chart supports deployment on the following Kubernetes cloud providers:

| Provider | Status | Required Configuration | Notes |
|----------|--------|------------------------|-------|
| **AWS (EKS)** | ✅ Supported | See [aws/README.md](/aws/README.md) | Full support with auto-scaling, EBS volumes |
| **Google Cloud (GKE)** | ✅ Supported | See [google/README.md](/google/README.md) | Full support with auto-scaling, persistent disks |
| **Azure (AKS)** | ✅ Supported | `--set provider.name=azure` | Full support with managed disks |
| **OpenStack** | ✅ Supported | `--set provider.name=openstack` | Full support with Cinder storage |
| **Other Providers** | ⚠️ Partial | Custom configuration may be required | See "Custom Providers" section below |

### Custom Providers

If you are deploying to a Kubernetes cluster on a provider not listed above (e.g., Rancher, on-premises, or other cloud providers), you will need to:

1. **Configure Storage Classes**: Update the `provider.name` value and ensure your cluster has appropriate storage provisioners (e.g., local storage, NFS, or vendor-specific provisioners)
2. **Update StorageClass Parameters**: Edit `openstudio-server/templates/storageclass/storageclass.yaml` to add a new provisioner block for your infrastructure
3. **Node Labels**: Ensure your nodes have the required labels for scheduling constraints (see node affinity requirements in deployment templates)

For more information on configuring custom cloud providers, see the Helm chart values in `values.yaml`.

To uninstall/delete the `openstudio-server` helm chart:

```bash
helm uninstall openstudio-server
```

The command removes all the Kubernetes components associated with the chart and deletes the release _including_ persistent volumes. See more about persistent volumes below.

## Configuration

The following table lists the configurable parameters of the OpenStudio-server chart and their default values. You can override any of these values by specifying each parameter using the `--set key=value[,key=value]` argument to `helm install`. For example, to change the data storage for NFS which stores the data points to 300GB you would run this install command:

### For Google

```bash
helm install openstudio-server ./openstudio-server --set provider.name=google --set nfs-server-provisioner.persistence.size=300Gi
```

### For Amazon

```bash
helm install openstudio-server ./openstudio-server --set provider.name=aws --set nfs-server-provisioner.persistence.size=300Gi
```

### For Azure

```bash
helm install openstudio-server ./openstudio-server --set provider.name=azure --set nfs-server-provisioner.persistence.size=300Gi
```

Parameter | Description | Default
--------- | ----------- | -------
nfs-server-provisioner.persistence.size | Size of the volume for storing the data point results | 2Ti |
db.persistence.size | Size of the volume for MongoDB | 500Gi |
cluster.name | Kubernetes AWS or Google cluster name. If you change the default name you need to set this name here otherwise AWS auto-scaling will not work correctly | openstudio-server |
worker_hpa.minReplicas | Worker pods that run the simulations | 2 |
worker_hpa.maxReplicas | Maximum Worker pods that run the simulations | 15000 |
worker_hpa.targetCPUUtilizationPercentage | When aggregate CPU % of worker pods exceed threshold begin scaling. | 35 |
worker_hpa.scaleUpPolicyValue | Maximum pods to add per scale-up interval. | 500 |
worker_hpa.scaleDownPolicyValue | Maximum pods to remove per scale-down interval. | 25 |
worker.queues | Resque queue priority order for worker pods. Left-most queue has highest priority. | simulations,requeued |
worker.podDisruptionBudget.enabled | Enable worker PodDisruptionBudget to reduce voluntary disruption churn during drain/scale-down. | true |
worker.podDisruptionBudget.minAvailable | Minimum available worker pods during voluntary disruptions. | 1 |
web.readinessProbe.path | Web readiness HTTP path. Use lightweight endpoint (`/`) to avoid probe flapping on large `/analyses.json`. | / |
web_background_hpa.enabled | Enable a Helm-managed HPA for `web-background`. When enabled, the queue autoscaler stops managing `web-background` replicas directly. | false |
web_background_hpa.minReplicas | Minimum `web-background` pods. | 1 |
web_background_hpa.maxReplicas | Maximum `web-background` pods. | 1 |
web_background_hpa.targetCPUUtilizationPercentage | CPU target used by the `web-background` HPA. | 60 |
web_background_keda.enabled | Enable KEDA queue-based scaling for `web-background`. Requires KEDA CRDs/operator in the cluster. | false |
web_background_keda.queueName | Redis list key watched by KEDA for `web-background` scaling. For Resque, use `resque:queue:<name>`. | resque:queue:analyses |
web_background_keda.listLength | Target Redis list length per replica for the KEDA scaler. | 25 |
web_background_keda.redisAddress | Redis service address used by KEDA; use the full service DNS name for cross-namespace installs. | queue.openstudio-server.svc.cluster.local:6379 |
redis.persistence.enabled | Enable persistent Redis storage (PVC). Set false to use ephemeral `emptyDir` storage. | true |
redis.affinity.enabled | Constrain Redis to specific nodes using node affinity. Set false if Redis is pending due to missing node labels or capacity. | true |
redis.affinity.nodegroupKey | Node label key used when Redis affinity is enabled. | nodegroup |
redis.affinity.nodegroupValues | Allowed label values for Redis node affinity. | [web-group] |
web_background.replicas  | Number of projects/analyses to run in parallel. __*Note__ Algorithmic runs are currently not supported to run in parallel. Keep default value of 1 for these types of analyses.  | 1 |
web_background.queues | Resque queue list consumed by web-background workers. Recommended to reserve this deployment for analysis-feeder queues. | analysis_wrappers,analyses |
rserve.livenessProbe.timeoutSeconds | Timeout for rserve mount/write liveness command; increase to tolerate transient NFS latency. | 30 |
rserve.livenessProbe.failureThreshold | Consecutive liveness failures before restart for rserve. | 6 |
web_background.container.image  | Container to run the web background. Can use a custom image to override default | nrel/openstudio-server:3.7.0 |
web.container.image   | Container to run the web front-end. Can use a custom image to override default | nrel/openstudio-server:3.7.0 |
worker.container.image   | Container to run the worker. Can use a custom image to override default | nrel/openstudio-server:3.7.0 |
rserve.container.image   | Container to run r server. Can use a custom image to override default | nrel/openstudio-rserve:3.7.0 |
s3_exporter.enabled | Enables targeted results export CronJob for CSV + manifest (and optional enrich zips) to S3 | false |
s3_exporter.schedule | Export CronJob schedule | */5 * * * * |
s3_exporter.bucket | Destination S3 bucket for exported artifacts | "" |
s3_exporter.prefix | Destination S3 prefix for exported artifacts | "" |
s3_exporter.serviceAccount.roleArn | Optional IRSA role ARN for exporter pod access to S3 | "" |

## Targeted S3 export for teardown-safe result downloads

This chart can run a targeted export CronJob that writes only `download_results`-oriented artifacts to S3:

- `manifest/analyses.json`
- `csv/<analysis_id>/<analysis_name>.csv`
- optional `enrich/data_point_zip/<data_point_id>.zip`

Enable with:

```bash
helm upgrade --install openstudio-server ./openstudio-server \
  --set s3_exporter.enabled=true \
  --set s3_exporter.bucket=<your-bucket> \
  --set s3_exporter.prefix=<your-prefix> \
  --set s3_exporter.serviceAccount.roleArn=arn:aws:iam::<account-id>:role/<irsa-role>
```

Before tearing down the node groups, run a final on-demand sync job and block teardown on failure:

```bash
./scripts/finalize-s3-export-and-teardown.sh \
  --namespace openstudio-server \
  --cronjob openstudio-server-s3-incremental-sync
```

Then scale down node groups (keeping cluster control plane intact):

```bash
# Scale worker node groups to 0 (adjust nodegroup names as needed)
eksctl scale nodegroup --cluster openstudio-server-03 --name worker-node-group-spot-2a --nodes 0 --region us-west-2
eksctl scale nodegroup --cluster openstudio-server-03 --name worker-node-group-spot-2b --nodes 0 --region us-west-2

# Or scale essential nodes if needed
eksctl scale nodegroup --cluster openstudio-server-03 --name web-group --nodes 0 --region us-west-2
```

Results remain accessible in S3 for post-teardown download via gem S3 fallback mode.

#### For Large Workloads
Use layered values files instead of manually copying templates:

```bash
helm upgrade --install openstudio-server ./openstudio-server \
  --set provider.name=aws \
  -f openstudio-server/values.yaml \
  -f openstudio-server/values_large.templateyaml
```

For reliability-first batch completion runs up to 15k workers, use:

```bash
helm upgrade --install openstudio-server ./openstudio-server \
  --set provider.name=aws \
  -f openstudio-server/values.yaml \
  -f openstudio-server/values_batch_15k.yaml
```

If you have KEDA installed and want `web-background` to scale on the `analyses` queue instead of CPU, use:

```bash
helm upgrade --install openstudio-server ./openstudio-server \
  --set provider.name=aws \
  -f openstudio-server/values.yaml \
  -f openstudio-server/values_batch_15k_keda.yaml
```

Additionally, note that with large workloads you may have issues with downloading container images from Docker Hub if you have a lot of worker nodes. Therefore, you may want to upload the container images into the cloud's container registry and then update the container image path in the [values file](/openstudio-server/values.yaml). This [article](https://docs.aws.amazon.com/AmazonECR/latest/userguide/docker-push-ecr-image.html#:~:text=Identify%20the%20local%20image%20to,container%20images%20on%20your%20system.&text=You%20can%20identify%20an%20image,tag%20name%20combination%20to%20use.) has instructions on how to do this for aws' Elastic Container Registry (ECR).

## Accessing OpenStudio Server

First make sure all the Kubernetes pods are up in running. You can confirm this by running:

```bash
kubectl get pods
```

example output of all pods running:

```bash
NAME                                                       READY   STATUS    RESTARTS   AGE
db-5ff59c484-hl468                                         1/1     Running   0          4m22s
openstudio-server-nfs-server-provisioner-884774d4f-8pm4d   1/1     Running   0          4m22s
redis-687fc94686-tkb9l                                     1/1     Running   0          4m22s
rserve-67cb86849b-jph25                                    1/1     Running   0          4m22s
web-694557fcc7-cd5q8                                       1/1     Running   0          4m22s
web-background-6968ff9cd5-58hbn                            1/1     Running   0          4m22s
worker-5cf4db9bbd-2pld8                                    1/1     Running   0          2m52s
worker-5cf4db9bbd-6n4pz                                    1/1     Running   0          4m7s
worker-5cf4db9bbd-bvv5z                                    1/1     Running   0          2m52s
worker-5cf4db9bbd-sm9s7                                    1/1     Running   0          4m22s
worker-5cf4db9bbd-z92xx                                    1/1     Running   0          2m52s
```
You can see CPU and memory utilization by running:

```bash
kubectl top pods
```

example output of all pods running:

```bash
NAME                                                       CPU(cores)   MEMORY(bytes)
db-5ff59c484-hl468                                         4m           171Mi
openstudio-server-nfs-server-provisioner-884774d4f-8pm4d   2m           110Mi
redis-687fc94686-tkb9l                                     2m           2Mi
rserve-67cb86849b-jph25                                    1m           78Mi
web-694557fcc7-cd5q8                                       2m           421Mi
web-background-6968ff9cd5-58hbn                            1m           182Mi
worker-5cf4db9bbd-2pld8                                    1m           172Mi
worker-5cf4db9bbd-6n4pz                                    1m           178Mi
worker-5cf4db9bbd-bvv5z                                    1m           172Mi
worker-5cf4db9bbd-sm9s7                                    1m           176Mi
worker-5cf4db9bbd-z92xx                                    1m           172Mi
```
Note that 1000m means one virtual CPU core.

You can also add `watch` to the beginning of the command to see the output change over time.

For periodic remediation, use `scripts/health-remediation-loop.sh`. It checks the cluster and release every 15 minutes, prefers `kubectl patch`-based rollouts, and escalates unresolved issues by email when configured:

```bash
NAMESPACE=openstudio-server RELEASE=openstudio-server ESCALATION_EMAIL=you@example.com \
  ./scripts/health-remediation-loop.sh
```

Set `ENFORCE_WORKER_HPA_MAX_REPLICAS=1` only when you want the loop to force worker HPA `maxReplicas` back to `SAFE_WORKER_MAX_REPLICAS` (default `15000`).  
Default is `0` so staged ramps can temporarily cap HPA max without remediation drift.

The loop also detects `FailedCreatePodSandBox` + `DeadlineExceeded/context deadline exceeded` and performs a bounded, per-node restart of the CNI daemonset pod (`kube-system`, selector `k8s-app=aws-node`) with cooldown controls:
`MAX_CNI_RESTARTS_PER_CYCLE` (default `2`) and `CNI_RESTART_COOLDOWN_SECONDS` (default `900`).

For queue-aware autoscaling, use `scripts/queue-autoscale-loop.sh`. It reads Redis queue depth and:
- scales `deployment/web-background` only when no `web-background` HPA or KEDA ScaledObject exists
- patches `hpa/worker-hpa.spec.minReplicas` based on the `simulations` queue
- enforces a ratio-based simulations queue floor against running workers (optional, enabled by default)

```bash
NAMESPACE=openstudio-server \
WEB_BACKGROUND_MIN_REPLICAS=1 \
WEB_BACKGROUND_MAX_REPLICAS=20 \
WORKER_MIN_REPLICAS_CEILING=15000 \
WORKER_MIN_REPLICAS_MAX_STEP_UP=200 \
WORKER_MIN_REPLICAS_MAX_STEP_DOWN=50 \
SIM_LOW_WATERMARK=800 \
SIMULATIONS_PER_RUNNING_WORKER_FLOOR=30 \
MIN_SIMULATIONS_QUEUE_FLOOR=800 \
MAX_SIMULATIONS_QUEUE_FLOOR=150000 \
SIMULATIONS_PER_WARM_WORKER=40 \
./scripts/queue-autoscale-loop.sh
```

`WORKER_MIN_REPLICAS_CEILING` defaults to `15000` to match `worker_hpa.maxReplicas`.
`WORKER_MIN_REPLICAS_MAX_STEP_UP` defaults to `200` and `WORKER_MIN_REPLICAS_MAX_STEP_DOWN` defaults to `50` to limit abrupt floor jumps.
`ENFORCE_SIM_QUEUE_RATIO_FLOOR` defaults to `1`.
`SIMULATIONS_QUEUE` defaults to `resque:queue:simulations` and `ANALYSES_QUEUE` defaults to `resque:queue:analyses`.
If `web_background_hpa.enabled=true`, `queue-autoscale-loop.sh` leaves `web-background` replica management to the HPA and only keeps worker floors aligned.

Useful one-shot dry run of the current scaling decision:

```bash
ONCE=1 ./scripts/queue-autoscale-loop.sh
```

For reliability-first worker ramping, use `scripts/worker-staged-ramp.sh` to cap HPA max in stages (`2k -> 5k -> 10k -> 15k`) and auto-rollback if sandbox failures spike:

```bash
NAMESPACE=openstudio-server \
SANDBOX_FAIL_THRESHOLD_5M=100 \
STAGES=2000,5000,10000,15000 \
HOLD_SECONDS=180 \
MIN_READY_RATIO=0.95 \
./scripts/worker-staged-ramp.sh
```

### Troubleshooting KEDA `keda-hpa-web-background` showing `0`

When `keda-hpa-web-background` shows `0/<target>`, first confirm KEDA is watching the same Redis key that Resque is writing:

```bash
kubectl -n openstudio-server get scaledobject web-background -o yaml | grep -E 'listName|address'
kubectl -n openstudio-server get hpa keda-hpa-web-background
REDIS_POD=$(kubectl -n openstudio-server get pods -l app=redis -o jsonpath='{.items[0].metadata.name}')
kubectl -n openstudio-server exec "$REDIS_POD" -c redis -- \
  redis-cli --no-auth-warning -a openstudio LLEN resque:queue:analyses
```

If the Redis queue key has backlog but the HPA metric stays at `0`, update `web_background_keda.queueName` to the correct list key (typically `resque:queue:analyses`) and redeploy.

If analyses are uploaded but never transition into queued simulations (`data_points` stuck at `status=na`), use `scripts/remediate-stalled-analyses.sh`. By default it is dry-run and only reports candidates; with `--execute` it clears stale analysis Redis keys and re-triggers `action.json` start for each stalled analysis:

```bash
# Dry-run report
./scripts/remediate-stalled-analyses.sh --lookback-hours 12 --stall-minutes 15

# Execute for one known analysis id
./scripts/remediate-stalled-analyses.sh --analysis-id <analysis-id> --execute
```

This chart now also includes a startup hotfix for the OpenStudio server app that:
1. allows `analysis_action=start` for `analysis_type=batch_run` and `analysis_type=lhs` (rejects unsupported types)
2. auto-chains `lhs` starts to `batch_run` so generated LHS datapoints are queued without requiring a second client call
3. converts `analysis:<id>:completed` Redis markers to expiring keys (`setex`) to avoid persistent stale completion flags

These controls are enabled by default and configurable in `openstudio-server/values.yaml` under `server_hotfix`.

Once the cluster is up and running, you can use `kubectl` to determine the external IP or DN to access OpenStudio server and use this in PAT to connect to. For example, on AWS, a0a4014d98f0211ea91cb06528280f48-1900622776.us-west-2.elb.amazonaws.com is the external name. See the examples below for each cloud provider.

AWS is the long domain (a0a4014d98f0211ea91cb06528280f48-1900622776.us-west-2.elb.amazonaws.com)

```bash
$ kubectl get svc ingress-load-balancer
NAME                    TYPE           CLUSTER-IP      EXTERNAL-IP                                                               PORT(S)                      AGE
ingress-load-balancer   LoadBalancer   10.100.246.21   a52e7c2e22f3940a8aa9d80b5220d468-1479205808.us-east-1.elb.amazonaws.com   80:32739/TCP,443:31344/TCP   5m56s
```

Google is 35.247.75.9

```bash
$ kubectl get svc ingress-load-balancer
NAME                    TYPE           CLUSTER-IP      EXTERNAL-IP   PORT(S)                      AGE
ingress-load-balancer   LoadBalancer   10.55.246.197   35.247.75.9   80:32613/TCP,443:31562/TCP   35m
```

Azure is 20.190.10.17

```bash
$ kubectl get svc ingress-load-balancer
NAME                                       TYPE           CLUSTER-IP    EXTERNAL-IP    PORT(S)  AGE
ingress-load-balancer                      LoadBalancer   10.0.248.18   20.190.10.17   80:31879/TCP 443:30780/TCP 3m53s
```

You will then use this EXTERNAL-IP to use with PAT to connect to an existing cloud server. In the AWS example, you would enter http://a0a4014d98f0211ea91cb06528280f48-1900622776.us-west-2.elb.amazonaws.com in PAT under Existing Server URL in PAT. For Google, http://35.247.75.9. For Azure, http://20.190.10.17

## Persistent Volumes

This helm chart provisions persistent storage for the Database (MongoDB) and the NFS server (storage for data results). These will persist throughout the life of the helm chart while it's running. It will **NOT** persist if you delete the helm chart. The volumes will be deleted along with it.

While it's possible to change the storage to use `Retain` vs `Delete`, the helm chart will need to be reconfigured to allow to attach to existing volumes. This will be worked on as an enhancement for a future release.

## Auto Scaling

The worker pods are configured to auto-scale based on CPU threshold (default 50%). Once the aggregate CPU for all worker pods exceeds the defined threshold, Kubernetes starts adding worker pods up to the configured maximum. This behavior also depends on your cluster autoscaler/node group limits. Please refer to the notes on [aws](/aws/README.md) and [google](/google/README.md) when setting up the cluster and note the instance type and maximum nodes specified.

Once aggregate worker CPU drops below threshold, Kubernetes starts removing worker pods according to HPA scale-down behavior. There is a [prestop hook](https://kubernetes.io/docs/concepts/containers/container-lifecycle-hooks/) configured in the worker pod to ensure that if an OpenStudio job is still active it will not terminate the pod until it is finished.
