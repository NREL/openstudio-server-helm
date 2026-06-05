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

## Configuration Setup

Before installing the chart, either use the tracked baseline `openstudio-server/values.yaml` or create your own values file from one of the provided templates:

- `values_small.templateyaml` - For small workloads and testing
- `values_large.templateyaml` - For large-scale production workloads
- `values_production.templateyaml` - For general production deployments (specifically openstack)

**Copy the appropriate template and customize it for your environment:**

```bash
cp openstudio-server/values_small.templateyaml openstudio-server/values.yaml
# OR
cp openstudio-server/values_large.templateyaml openstudio-server/values.yaml
# OR
cp openstudio-server/values_production.templateyaml openstudio-server/values.yaml
```

Then edit your chosen values file (for example `openstudio-server/values.yaml`) to:
- Set your cloud provider in `global.provider.name` (`google`, `aws`, `azure`, or `openstack`). This is required.
- Configure your app secret source:
  - Primary path: set `secrets.existingSecret` and keep `secrets.create=false`
  - Alternate path: set `secrets.create=true` and provide `db.username`, `db.password`, `redis.password`, and `web.secret_key_value`
- If Redis credentials include URI-reserved characters, set an explicit `redis.url` override (for example `redis://:encoded-password@queue:6379`).
- Adjust resource allocations for your workload
- Configure storage sizes

`provider.name` is deprecated and disabled by default. Any values file that still sets `provider.name` should be migrated to `global.provider.name`.
For temporary migration-only compatibility, you can opt in with:

```yaml
global:
  provider:
    allowLegacyName: true
```

This legacy fallback is intended for staged upgrades only.

Provider-aware scheduling defaults are automatic and based on `global.provider.name`:

Provider | Label Key | Web Node Group | Worker Node Group
---------|-----------|----------------|------------------
openstack | `capi.stackhpc.com/node-group` | `web` | `worker`
aws/google/azure (default) | `nodegroup` | `web-group` | `worker-group`

Provider-aware infrastructure defaults are also automatic when values are omitted:

Setting | openstack default | aws/google/azure default
--------|-------------------|------------------------
`db.persistence.storageClass` | `nfs` | `ssd`
`redis.persistence.storageClass` | `nfs` | `ssd`
`load_balancer.externalTrafficPolicy` | `Cluster` | `Local`

For OpenStack production deployments, `values_production.templateyaml` explicitly sets:

- `db.persistence.storageClass: cinder-csi`
- `redis.persistence.storageClass: cinder-csi`

This keeps MongoDB/Redis off the shared NFS assets volume used by worker outputs.

NFS mount options are intentionally conservative by default in template files:

- Default: `mountOptions: ["vers=4"]`
- Optional tuning (environment dependent): `sync`, `rsize=...`, `wsize=...`

These options are not cloud-provider features; compatibility depends on the Kubernetes node OS/kernel NFS client and the backing NFS server behavior.

If your cluster uses different label names, set overrides in `global.nodeGroups`:

```yaml
global:
  provider:
    name: "openstack"
  nodeGroups:
    labelKey: ""
    web: ""
    worker: ""
    affinityMode: "preferred"  # required | preferred | disabled
```

**Note:** `openstudio-server/values.yaml` is a tracked baseline for reproducible defaults. Put environment-specific or sensitive overrides in a separate local file (for example `openstudio-server/values.local.yaml`) and pass it with `-f`.

## Installing the Chart

To install the helm chart with the chart name `openstudio-server`, you can run the following command in the root directory of this repo. This assumes you already have a Kubernetes cluster up and running. If you do not, please refer to [google](/google/README.md) or [aws](/aws/README.md) in this repo.

### For Google

```bash
kubectl -n openstudio-server create secret generic openstudio-app-secrets \
  --from-literal=db-username="openstudio" \
  --from-literal=db-password="replace-with-strong-password" \
  --from-literal=redis-password="replace-with-strong-password" \
  --from-literal=web-secret-key="replace-with-long-random-secret"
helm upgrade --install openstudio-server ./openstudio-server \
  --namespace openstudio-server --create-namespace \
  --set global.provider.name=google
```

### For Amazon

```bash
kubectl -n openstudio-server create secret generic openstudio-app-secrets \
  --from-literal=db-username="openstudio" \
  --from-literal=db-password="replace-with-strong-password" \
  --from-literal=redis-password="replace-with-strong-password" \
  --from-literal=web-secret-key="replace-with-long-random-secret"
helm upgrade --install openstudio-server ./openstudio-server \
  --namespace openstudio-server --create-namespace \
  --set global.provider.name=aws
```

### For Azure

```bash
kubectl -n openstudio-server create secret generic openstudio-app-secrets \
  --from-literal=db-username="openstudio" \
  --from-literal=db-password="replace-with-strong-password" \
  --from-literal=redis-password="replace-with-strong-password" \
  --from-literal=web-secret-key="replace-with-long-random-secret"
helm upgrade --install openstudio-server ./openstudio-server \
  --namespace openstudio-server --create-namespace \
  --set global.provider.name=azure
```

### For OpenStack

Use an existing OpenStack-managed Kubernetes cluster when possible (for example, a cluster created through Azimuth or provided by your OpenStack administrators). This is the recommended path.

The `openstack/` directory in this repository contains legacy self-managed cluster automation (Terraform/OpenTofu + Kubespray). That path is not actively tested and may not work in all environments; use it at your own risk.

Once your Kubernetes cluster is available and your kubeconfig is configured, install the Helm chart:

```bash
kubectl -n openstudio-server create secret generic openstudio-app-secrets \
  --from-literal=db-username="openstudio" \
  --from-literal=db-password="replace-with-strong-password" \
  --from-literal=redis-password="replace-with-strong-password" \
  --from-literal=web-secret-key="replace-with-long-random-secret"
helm upgrade --install openstudio-server ./openstudio-server \
  --namespace openstudio-server --create-namespace \
  --set global.provider.name=openstack
```

`secrets.existingSecret` validation is enabled by default during install/upgrade:

```bash
--set secrets.validateExistingSecret=true
```

For offline/render-only workflows (for example CI `helm template` jobs without cluster access), explicitly disable lookup-based validation:

```bash
--set secrets.validateExistingSecret=false
```

The chart also supports chart-managed secret creation as an alternate mode:

```bash
helm upgrade --install openstudio-server ./openstudio-server \
  --namespace openstudio-server --create-namespace \
  --set global.provider.name=google \
  --set secrets.existingSecret= \
  --set secrets.create=true \
  --set db.username=openstudio \
  --set db.password=replace-with-strong-password \
  --set redis.password=replace-with-strong-password \
  --set web.secret_key_value=replace-with-long-random-secret
```

**Note:** Instead of repeated `--set` flags, prefer an environment-specific values file and pass it with `-f`.
Use `./scripts/install-dry-run.sh` to run lint/render checks across default and OpenStack values before deployment.
For a quick install helper script, run `PROVIDER=openstack ./scripts/install.sh` (supported providers: `aws`, `google`, `azure`, `openstack`).

`scripts/install.sh` now fails fast on secret validation by default:

- Default mode: `SECRET_MODE=existing` and `EXISTING_SECRET_NAME=openstudio-app-secrets`
- Required behavior: if `NAMESPACE` does not exist, the script creates it before validating the secret. The existing secret must then exist in that namespace and contain non-empty keys:
  - `db-username`
  - `db-password`
  - `redis-password`
  - `web-secret-key`
- Alternate mode: set `SECRET_MODE=create` and provide `DB_USERNAME`, `DB_PASSWORD`, `REDIS_PASSWORD`, and `WEB_SECRET_KEY`
  - In create mode, `scripts/install.sh` writes credentials to a temporary values file and passes it with `--values` (instead of secret-bearing `--set` flags), then removes the file on exit.

To run secret preflight directly:

```bash
./scripts/validate-app-secret.sh --namespace openstudio-server --secret-name openstudio-app-secrets
```

## Uninstalling the Chart

To uninstall/delete the `openstudio-server` helm chart:

```bash
helm uninstall openstudio-server
```

The command removes all the Kubernetes components associated with the chart and deletes the release _including_ persistent volumes. See more about persistent volumes below.

## Configuration

The following table lists the configurable parameters of the OpenStudio-server chart and their default values. You can override any of these values in your `values.yaml` file (see Configuration Setup section above).

For example, to change the data storage for NFS which stores the data points to 1Ti, modify the `nfs-server-provisioner.persistence.size` parameter in your `values.yaml`:

```yaml
nfs-server-provisioner:
  persistence:
    size: 1Ti

nfs_pvc:
  storage: 900Gi
```

**Sizing rule:** `nfs_pvc.storage` must stay below `nfs-server-provisioner.persistence.size` (recommended 85-95%) so dynamic NFS claim provisioning has filesystem/provisioner headroom.

Parameter | Description | Default
--------- | ----------- | -------
nfs-server-provisioner.persistence.size | Size of the volume for storing the data point results | 550Gi |
nfs_pvc.storage | Shared RWX claim request consumed by web/rserve/background pods; keep below backend NFS size | 500Gi |
db.persistence.size | Size of the volume for MongoDB | 200Gi |
global.provider.allowLegacyName | Temporary migration flag that permits legacy `provider.name` only when `global.provider.name` is unset | false |
cluster.name | Kubernetes AWS or Google cluster name. If you change the default name you need to set this name here otherwise AWS auto-scaling will not work correctly | openstudio-server |
worker_hpa.minReplicas | Worker pods that run the simulations | 2 |
worker_hpa.maxReplicas | Maximum Worker pods that run the simulations | 50 |
worker_hpa.targetCPUUtilizationPercentage | When aggregate CPU % of worker pods exceed threshold begin scaling. | 50 |
worker.queues | Comma-separated worker queues consumed by simulation workers. Include `requeued` to drain requeue backlog automatically. | simulations,requeued |
redis.url | Optional explicit Redis URI used for `REDIS_URL`; recommended when credentials contain URI-reserved characters | "" |
web_background.replicas  | Number of projects/analyses to run in parallel. __*Note__ Algorithmic runs are currently not supported to run in parallel. Keep default value of 1 for these types of analyses.  | 1 |
global.images.org | Docker image organization/registry namespace for OpenStudio images | nrel |
global.images.serverRepository | Repository name used by web, web-background, and worker containers | openstudio-server |
global.images.rserveRepository | Repository name used by rserve container | openstudio-rserve |
global.images.tag | Shared image tag used for both server and rserve repositories | 3.10.0 |
web_background.container.image  | Optional explicit override for web-background image. If omitted, chart uses global.images.* defaults | (derived) |
web.container.image   | Optional explicit override for web image. If omitted, chart uses global.images.* defaults | (derived) |
worker.container.image   | Optional explicit override for worker image. If omitted, chart uses global.images.* defaults | (derived) |
rserve.container.image   | Optional explicit override for rserve image. If omitted, chart uses global.images.* defaults | (derived) |

**Note:** For best practices, create your own `values.yaml` from one of the template files rather than modifying configuration via `--set` flags. See the Configuration Setup section above.

#### For Large Workloads
Use the [large template values file](/openstudio-server/values_large.templateyaml) as your starting point:

```bash
cp openstudio-server/values_large.templateyaml openstudio-server/values.yaml
```

Then customize as needed before running `helm upgrade --install`.

Additionally, note that with large workloads you may have issues with downloading container images from Docker Hub if you have a lot of worker nodes. Therefore, you may want to upload the container images into the cloud's container registry and then update the container image paths in your `values.yaml` file. This [article](https://docs.aws.amazon.com/AmazonECR/latest/userguide/docker-push-ecr-image.html#:~:text=Identify%20the%20local%20image%20to,container%20images%20on%20your%20system.&text=You%20can%20identify%20an%20image,tag%20name%20combination%20to%20use.) has instructions on how to do this for aws' Elastic Container Registry (ECR).

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

Once the cluster is up and running, you can use `kubectl` to determine the external IP or DN to access OpenStudio server and use this in PAT to connect to. For example, on AWS, a0a4014d98f0211ea91cb06528280f48-1900622776.us-west-2.elb.amazonaws.com is the external name. See the examples below for each cloud provider.

AWS is the long domain (a0a4014d98f0211ea91cb06528280f48-1900622776.us-west-2.elb.amazonaws.com)

```bash
kubectl get svc ingress-load-balancer
```

example output:

```bash
NAME                    TYPE           CLUSTER-IP      EXTERNAL-IP                                                               PORT(S)                      AGE
ingress-load-balancer   LoadBalancer   10.100.246.21   a52e7c2e22f3940a8aa9d80b5220d468-1479205808.us-east-1.elb.amazonaws.com   80:32739/TCP,443:31344/TCP   5m56s
```

Google is 35.247.75.9

```bash
kubectl get svc ingress-load-balancer
```

example output:

```bash
NAME                    TYPE           CLUSTER-IP      EXTERNAL-IP   PORT(S)                      AGE
ingress-load-balancer   LoadBalancer   10.55.246.197   35.247.75.9   80:32613/TCP,443:31562/TCP   35m
```

Azure is 20.190.10.17

```bash
kubectl get svc ingress-load-balancer
```

example output:

```bash
NAME                                       TYPE           CLUSTER-IP    EXTERNAL-IP    PORT(S)  AGE
ingress-load-balancer                      LoadBalancer   10.0.248.18   20.190.10.17   80:31879/TCP 443:30780/TCP 3m53s
```

You will then use this EXTERNAL-IP to use with PAT to connect to an existing cloud server. In the AWS example, you would enter http://a0a4014d98f0211ea91cb06528280f48-1900622776.us-west-2.elb.amazonaws.com in PAT under Existing Server URL in PAT. For Google, http://35.247.75.9. For Azure, http://20.190.10.17

## Persistent Volumes

This helm chart provisions persistent storage for the Database (MongoDB) and the NFS server (storage for data results). These will persist throughout the life of the helm chart while it's running. It will **NOT** persist if you delete the helm chart. The volumes will be deleted along with it.

While it's possible to change the storage to use `Retain` vs `Delete`, the helm chart will need to be reconfigured to allow to attach to existing volumes. This will be worked on as an enhancement for a future release.

### NFS Saturation Recovery (No-Pruning Retention)

If OpenStudio begins returning HTTP 500 and MongoDB logs show `No space left on device`, recover in this order:

```bash
# 1) Confirm NFS backend fullness and impacted pods
kubectl -n openstudio-server get pods
kubectl -n openstudio-server logs deploy/db --tail=100
kubectl -n openstudio-server exec deploy/openstudio-server-nfs-server-provisioner -- df -h /export

# 2) Verify storage classes and expansion support
kubectl -n openstudio-server get pvc nfs-pvc-data -o jsonpath='{.spec.storageClassName}{"\n"}'
kubectl get storageclass <storage-class-from-command-above> -o yaml | grep -i allowVolumeExpansion

# 3) Expand backend volume claim used by nfs-server-provisioner (example to 1Ti)
kubectl -n openstudio-server patch pvc nfs-pvc-data \
  -p '{"spec":{"resources":{"requests":{"storage":"1Ti"}}}}'

# 4) Wait for resize to complete, then restart impacted services
kubectl -n openstudio-server get pvc nfs-pvc-data -w
kubectl -n openstudio-server exec deploy/openstudio-server-nfs-server-provisioner -- df -h /export
kubectl -n openstudio-server rollout restart deploy/db deploy/web deploy/web-background
kubectl -n openstudio-server rollout status deploy/db
kubectl -n openstudio-server rollout status deploy/web
```

Notes:

- `nfs-server-provisioner.persistence.size` controls backend capacity for all dynamic `nfs` claims.
- `nfs_pvc.storage` should be configured smaller than `nfs-server-provisioner.persistence.size` (recommended 85-95%); requesting equal size can fail provisioning due to overhead/headroom checks.
- `nfs_pvc.storage` is a request value; it is not an independent quota when backed by the same NFS server volume.
- Existing PVC `storageClassName` is immutable. If migrating DB/Redis from NFS to block storage, use a planned migration window with backup/restore.

### Reliability Preflight, Snapshot, and Helm Reconcile Automation

Use `scripts/openstudio-reliability` to standardize triage and recovery steps:

```bash
# Read-only reliability checks (recommended first step)
./scripts/openstudio-reliability --mode check

# Capture queue/job snapshots before any mutation
./scripts/openstudio-reliability --mode snapshot \
  --snapshot-dir ./incident-snapshots/openstudio-server-$(date +%Y%m%d-%H%M%S)

# Reconcile Helm only for managed-field conflict failures
./scripts/openstudio-reliability --mode reconcile-helm --apply --allow-chart-apply

# Recover stuck analyses (stale started jobs/datapoints; apply-gated)
./scripts/openstudio-reliability --mode recover-stuck --stale-minutes 70 --apply
```

Design notes:

- Script defaults to read-only mode.
- Mutating operations require explicit `--apply`.
- Snapshot mode captures queue depths and app job status for incident auditability.

### Helm Failed-State Reconcile Playbook (SSA Conflicts)

If `helm status` is `failed` while workloads are healthy, and the description includes managed-field conflict errors (for example `.spec.replicas` or HPA fields), use this sequence.

Do **not** run reconcile if:

- workloads are unstable (crashing, unavailable, or actively recovering),
- failure reason is unknown or unrelated to managed-field conflicts,
- local chart changes are unreviewed for production.

```bash
# 1) Confirm actual runtime health first
kubectl -n openstudio-server get pods
kubectl -n openstudio-server get deploy worker
kubectl -n openstudio-server get hpa worker -o wide

# 2) Confirm release failure reason
helm status openstudio-server -n openstudio-server
helm history openstudio-server -n openstudio-server

# 3) Reconcile using guarded helper (includes dry-run preflight)
./scripts/openstudio-reliability --mode reconcile-helm --apply --allow-chart-apply

# 4) Validate release and runtime gates
helm status openstudio-server -n openstudio-server
kubectl -n openstudio-server get pods
kubectl -n openstudio-server get hpa worker -o wide
kubectl -n openstudio-server exec deploy/redis -- sh -lc 'PW="${REDIS_PASSWORD:-}"; AUTH=""; [ -n "$PW" ] && AUTH="-a $PW --no-auth-warning"; redis-cli $AUTH LLEN resque:queue:simulations'

# 5) Roll back if release or runtime regresses
helm rollback openstudio-server <last-good-revision> -n openstudio-server
```

### Stuck Analysis Recovery Playbook (Queue/State Divergence)

If analyses remain in `started` while queues are empty or `requeued` backlog exists, use this sequence.

```bash
# 1) Confirm divergence and capture evidence
./scripts/openstudio-reliability --mode check --stale-minutes 70
./scripts/openstudio-reliability --mode snapshot \
  --stale-minutes 70 \
  --snapshot-dir ./incident-snapshots/openstudio-server-$(date +%Y%m%d-%H%M%S)

# 2) Apply guarded recovery
./scripts/openstudio-reliability --mode recover-stuck --stale-minutes 70 --apply

# 3) Re-check health and convergence
./scripts/openstudio-reliability --mode check --stale-minutes 70
```

Guardrails:

- Recovery is apply-gated and uses a Redis lock to prevent concurrent remediation runs.
- Recovery only mutates stale entries older than the configured threshold.
- Batch-run jobs are finalized only when all datapoints are terminal.

### Postmortem Template and Corrective-Action Checklist

For each production incident, capture:

1. Trigger, impact window, and user-visible symptoms.
2. Root cause chain (technical + operational contributing factors).
3. Detection latency and which alert should have fired earlier.
4. Immediate mitigations applied and why they were chosen.
5. Permanent fixes across defaults, automation, and docs.
6. Drill plan and verification date for each corrective action.
7. Owner per action item with objective completion criteria.

Recent stuck-state retrospective findings (used for this runbook hardening):

- Worker defaults consumed `simulations` but not `requeued`, allowing requeued work to stall indefinitely.
- Infrastructure health (`helm status`, pod readiness) can remain green while app-level analysis state diverges.
- Reliable recovery requires both queue remediation and state convergence checks (not just Helm reconcile).

### Alerting Baseline (Recommended)

Minimum production alerts to add in your platform monitoring:

Metric | Warning | Critical | Rationale
------ | ------- | -------- | ---------
NFS `/export` free space | `<20%` | `<10%` | Early detection before DB/asset write failures.
NFS fill projection (time-to-full) | `<7 days` | `<2 days` | Catch rapid growth even when free space still appears high.
Redis `resque:queue:simulations` backlog age | `>15m` | `>30m` | Detect worker throughput mismatch.
Queue/job divergence (`Job(status='queued')` with near-empty Redis queues) | `>5 queued for 10m` | `>20 queued for 10m` | Detect scheduler enqueue drift.
Worker HPA saturation (`current/target` CPU) | `>90% for 10m` | `>95% for 15m` | Detect sustained compute bottleneck.
Helm release state | `failed` | `failed for >15m` | Ensure operator metadata is reconciled quickly.

### Reliability Drill Cadence

Run a monthly drill that executes:

1. `./scripts/openstudio-reliability --mode check`
2. `./scripts/openstudio-reliability --mode snapshot --snapshot-dir <drill-artifacts>`
3. Helm reconcile dry procedure review (no mutation), then controlled reconcile in non-prod.
4. Post-drill retrospective with action-item updates.

## Auto Scaling

The worker pods are configured to auto-scale based on CPU threshold (default 12%). Once the aggregate CPU for all worker pods exceed the defined threshold (in this case 12%), the Kubernetes engine will start adding additional worker pods up to the maximum specified. This is also dependent on how the Kuebernetes cluster was configured as additional VM node instances will also be added. Please refer to the notes on [aws](/aws/README.md) and [google](/google/README.md) when setting up the cluster and note the instance type and maximum nodes specified.

Once the aggregate CPU of the workers drop below 12%, the Kubernetes engine will start removing worker pod instances. There is a [prestop hook](https://kubernetes.io/docs/concepts/containers/container-lifecycle-hooks/) configured in the worker pod to ensure that if a openstudio job is still active it will not terminate the pod until it is finished.
