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
- If using queue-based worker autoscaling (`worker_autoscaling.mode: keda-hybrid`), install KEDA first: [Install KEDA (self-managed prerequisite)](#install-keda-self-managed-prerequisite).

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
- For OpenStack, run a storage quota preflight before install/upgrade (see below)

`provider.name` is deprecated and disabled by default. Any values file that still sets `provider.name` should be migrated to `global.provider.name`.
For temporary migration-only compatibility, you can opt in with:

```yaml
global:
  provider:
    allowLegacyName: true
```

This legacy fallback is intended for staged upgrades only.

Provider-aware scheduling defaults are automatic and based on `global.provider.name`:

| Provider                   | Label Key                      | Web Node Group | Worker Node Group |
| -------------------------- | ------------------------------ | -------------- | ----------------- |
| openstack                  | `capi.stackhpc.com/node-group` | `web`          | `worker`          |
| aws/google/azure (default) | `nodegroup`                    | `web-group`    | `worker-group`    |

Provider-aware infrastructure defaults are also automatic when values are omitted:

| Setting                               | openstack default | aws/google/azure default |
| ------------------------------------- | ----------------- | ------------------------ |
| `db.persistence.storageClass`         | `nfs`             | `ssd`                    |
| `redis.persistence.storageClass`      | `nfs`             | `ssd`                    |
| `load_balancer.externalTrafficPolicy` | `Cluster`         | `Local`                  |

For OpenStack production deployments, `values_production.templateyaml` explicitly sets:

- `db.persistence.storageClass: csi-cinder`
- `redis.persistence.storageClass: csi-cinder`

This keeps MongoDB/Redis off the shared NFS assets volume used by worker outputs.

### OpenStack Storage Quota Preflight (Required)

Before `helm install` / `helm upgrade`, verify requested storage fits Cinder quota:

```text
nfs-server-provisioner.persistence.size
+ db.persistence.size
+ redis.persistence.size
+ existing in-use Cinder GB
<= Cinder quota GB
```

If this check fails, `nfs-pvc-data` can stay `Pending` with `413 VolumeSizeExceedsAvailableQuota`. That blocks the NFS provisioner pod, which then blocks `nfs-pvc`, and finally keeps `web`, `web-background`, and `rserve` in `Pending`.

For existing releases, PVC request size is immutable in-place for reductions. If live DB/Redis claims are already larger than your local values file, keep values aligned with the live size (or plan a migration/recreate window) before `helm upgrade`.

Use the local zot registry endpoint for NFS provisioner pulls:

```yaml
nfs-server-provisioner:
  image:
    repository: "erezsh2/nfs-provisioner"
    tag: "v2.3.0"
```

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
    affinityMode: "preferred" # required | preferred | disabled
    # Optional per-role overrides:
    # webAffinityMode: "preferred"
    # workerAffinityMode: "required"
```

For internal/private image registries, use the tracked profile `openstudio-server/values.registry-live.yaml` as the starting point, then copy it to a local override:

```bash
cp openstudio-server/values.registry-live.yaml openstudio-server/values.local.yaml
```

At minimum, set image source and auth:

```yaml
global:
  images:
    registry: "172.29.166.222:5000"
    repositoryPrefix: "" # optional
    org: "nrel"
    serverRepository: "openstudio-server"
    rserveRepository: "openstudio-rserve"
    tag: "3.10.0"
  imagePullSecrets:
    - "registry-credentials"

serviceAccount:
  create: true
  name: "openstudio-workload"
  imagePullSecrets:
    - "registry-credentials"
```

`global.images.registry` is the central registry host for chart-managed images (for example `172.29.166.222:5000` or `registry.example.com`). Bare names like `zot` are parsed as Docker Hub namespaces, which causes rate-limit pulls from `docker.io`.

Image auth precedence:

1. Pod-level `global.imagePullSecrets` (if set)
2. ServiceAccount-level pull secrets (`serviceAccount.imagePullSecrets`)
3. Cluster/node runtime auth configuration

If image pulls still resolve to a mirrored path like `quay.io/v2/azimuth/...`, that is a node runtime registry mirror problem, not a Helm values problem. Fix the containerd mirror config on the nodes or point the workload at a registry the nodes can reach directly.

For OpenStack/Azimuth environments, prefer cache-friendly pull behavior and configurable init pulls:

```yaml
web:
  initContainer:
    image: "" # defaults to openstudio server image
    imagePullPolicy: "" # defaults by provider (openstack=IfNotPresent)
  container:
    imagePullPolicy: ""
web_background:
  container:
    imagePullPolicy: ""
worker:
  container:
    imagePullPolicy: ""
```

For the Azimuth 179D cluster, keep the web stack off the worker pool by making web affinity required:

```yaml
global:
  nodeGroups:
    webAffinityMode: "required"
```

If you keep node-level registry host patching enabled, constrain it to the worker pool:

```yaml
registryHostsPatch:
  nodeSelector:
    capi.stackhpc.com/node-group: "worker"
```

For very large analysis batches, you can temporarily enable prepull (`prepull.enabled: true`). The chart now uses a tiny bootstrap image plus host `ctr` pulls with a randomized spread window, which avoids stamping the registry with hundreds of large image pulls at once. You can still opt into extra images with `prepull.includeRserve: true`, `prepull.includeWebInit: true`, and tune `prepull.spreadSeconds` if you need a slower ramp.

Optional image warmup before large scale-up:

```yaml
prepull:
  enabled: true
  role: "" # "", "web", or "worker"
  utilityImage: "registry.k8s.io/e2e-test-images/busybox:1.29-2"
  utilityImagePullPolicy: "IfNotPresent"
  spreadSeconds: 300 # per-node jitter before host pulls begin
  includeRserve: false
  includeWebInit: false
  additionalImages: [] # keep this empty unless you are actively pre-warming a new image
  warmMode: "once" # "once" | "continuous"
  intervalSeconds: 1200 # re-pull interval for continuous mode
  failOnAnyPullError: false # keep the warmup non-fatal in steady state
```

Treat prepull as a maintenance action, not a permanent control loop. Keep it worker-only and remove extra images unless you are intentionally pre-warming a rollout.

Optional pod-level registry host fallback:

```yaml
hostAliases:
  enabled: true
  entries:
    - ip: "10.60.127.127"
      hostnames:
        - "pulp-dev.hpc.nlr.gov"
        - "pulp-dev.hpc.nrel.gov"
```

Optional explicit node placement override:

```yaml
worker:
  nodeSelector:
    capi.stackhpc.com/node-group: "worker"
prepull:
  nodeSelector:
    capi.stackhpc.com/node-group: "worker"
registryHostsPatch:
  nodeSelector:
    capi.stackhpc.com/node-group: "worker"
```

For pull-storm prevention during worker scale-up, tune worker HPA behavior directly in values:

```yaml
worker_hpa:
  minReplicas: 800
  maxReplicas: 1200
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 120
      selectPolicy: Min
      policies:
        - type: Pods
          value: 20
          periodSeconds: 60
    scaleDown:
      stabilizationWindowSeconds: 300
      selectPolicy: Max
      policies:
        - type: Percent
          value: 15
          periodSeconds: 60
```

Recommended staged ramp workflow (very conservative):

1. Ensure prepull DaemonSet is healthy and `ImagePullBackOff` is near zero.
2. Run a sustained quiet-window gate before each cap increase:
   ```bash
   ./scripts/openstudio-reliability --mode ceiling-probe \
     --quiet-window-seconds 900 \
     --quiet-interval-seconds 30 \
     --probe-step-replicas 50
   ```
3. Increase worker cap in small steps (for example +50) **only** when `RECOMMENDATION=advance`, then wait for readiness convergence.
4. If `RECOMMENDATION=hold` (or if post-step health regresses), keep/revert to the last stable cap and investigate blockers.

When doing a pre-scale health check, also review recent warning events for:

- `NodeNotReady`
- `NetworkNotReady` / `FailedCreatePodSandBox`
- `failed to sync secret cache`
- `SystemOOM`
- `ImagePullBackOff` / `ErrImagePull`
- Octavia `503 Service Unavailable`

Treat `FailedCreatePodSandBox` and `failed to sync secret cache` as hard stop conditions for any further worker ramp.

Also pause further scaling if any node reports `MemoryPressure` or if you see repeated liveness-probe/OOM events; keep the worker ceiling aligned to the stable ready node count until those clear.

For Octavia, check `ingress-load-balancer` service events during ramp tests. Transient `SyncLoadBalancerFailed`/`503 Service Unavailable` warnings are provider-side noise if they clear, but repeated failures should be escalated instead of treated as a chart regression.

If you use `scripts/install.sh`, you can enable the same profile directly:

```bash
PROVIDER=openstack \
REGISTRY_PROFILE=true \
REGISTRY_VALUES_FILE=./openstudio-server/values.registry-live.yaml \
REGISTRY_PULL_SECRET_NAME=registry-credentials \
./scripts/install.sh
```

`REGISTRY_PULL_SECRET_NAME` wires both `global.imagePullSecrets` and `serviceAccount.imagePullSecrets` at install time.

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
Use `./scripts/install-dry-run.sh` to run lint/render checks across default and OpenStack values before deployment. This script enforces `values.schema.json` validation via `helm lint` before rendering templates.
These same checks are CI-enforced in `.github/workflows/chart-validation.yml`, so local runs match pull request validation.
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
helm uninstall openstudio-server -n openstudio-server
```

The command removes all the Kubernetes components associated with the chart and deletes the release _including_ persistent volumes. See more about persistent volumes below.

## Upgrade Notes

### PVC size immutability

PVC storage requests cannot be reduced in-place. If live DB, Redis, or NFS claims are
already larger than your local values file, align the values file with the live size
before running `helm upgrade`, or schedule a migration/recreate window.

```yaml
# Match these to actual live claim sizes before upgrading:
nfs-server-provisioner.persistence.size: <live-value>
db.persistence.size: <live-value>
redis.persistence.size: <live-value>
```

### Preserving worker HPA cap across upgrades

`worker_hpa.maxReplicas` is rendered into the HPA every `helm upgrade`. If you patched
the cap directly on the live HPA without updating your values file, Helm will revert it
on next upgrade. Before upgrading, confirm the value in your active overlay
(`values.registry-live.yaml` or equivalent) matches the live HPA:

```bash
kubectl get hpa openstudio-server-worker -n openstudio-server \
  -o jsonpath='{.spec.maxReplicas}'
```

Use `--reuse-values` to keep all previously set chart values, then pass only the
parameters you intend to change via `-f` or `--set`.

### Schema validation (added in 0.5.x)

`values.schema.json` enforces types and required fields. If a `helm upgrade` fails with
a schema validation error after a chart update, check the error message for the
offending key and update your values override to match the required type or enum.

Common causes:
- `worker_hpa.scaleTargetRef.name` or `.apiVersion` missing (set in values or
  `worker_hpa.scaleTargetRef` block).
- `autoscaler` block referencing keys removed or renamed in the new schema.

Run `helm lint ./openstudio-server -f your-override.yaml` locally to catch schema
errors before applying to the cluster.

### Using --reuse-values safely

`helm upgrade --reuse-values` merges the previous release's values with any new `-f`
overrides. This is safe for routine upgrades. Avoid it when the chart version introduces
new required fields or changes defaults for existing keys — in those cases, diff your
overlay against `values.yaml` defaults first:

```bash
helm show values ./openstudio-server > /tmp/defaults.yaml
diff /tmp/defaults.yaml your-overlay.yaml
```

### Verifying the deployment (helm test)

After `helm install` or `helm upgrade`, run the built-in chart tests to verify that the
web and Redis services are reachable:

```bash
helm test openstudio-server -n openstudio-server
```

The tests deploy short-lived Pods that:
- `web-test-healthcheck` — sends an HTTP request to the web service and expects a `200`
  or `302` response.
- `redis-test-ping` — runs `redis-cli PING` against the Redis service and expects
  `PONG`.

Both Pods are automatically deleted on success (`hook-delete-policy: hook-succeeded`).
On failure, the Pod remains for log inspection:

```bash
kubectl logs -n openstudio-server <pod-name>
```

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

| Parameter                                          | Description                                                                                                                                                                      | Default                |
| -------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------- |
| nfs-server-provisioner.persistence.size            | Size of the volume for storing the data point results                                                                                                                            | 200Gi                  |
| nfs-server-provisioner.deploymentStrategyType      | Deployment strategy for single-replica NFS provisioner (`Recreate` avoids RWO multi-pod contention during upgrades)                                                              | Recreate               |
| nfs_pvc.storage                                    | Shared RWX claim request consumed by web/rserve/background pods; keep below backend NFS size                                                                                     | 180Gi                  |
| db.persistence.size                                | Size of the volume for MongoDB                                                                                                                                                   | 300Gi                  |
| global.provider.allowLegacyName                    | Temporary migration flag that permits legacy `provider.name` only when `global.provider.name` is unset                                                                           | false                  |
| cluster.name                                       | Kubernetes AWS or Google cluster name. If you change the default name you need to set this name here otherwise AWS auto-scaling will not work correctly                          | openstudio-server      |
| worker_hpa.minReplicas                             | Worker pods that run the simulations                                                                                                                                             | 2                      |
| worker_hpa.maxReplicas                             | Maximum Worker pods that run the simulations                                                                                                                                     | 50                     |
| worker_hpa.targetCPUUtilizationPercentage          | When aggregate CPU % of worker pods exceed threshold begin scaling.                                                                                                              | 50                     |
| worker_autoscaling.mode                            | Worker autoscaling mode: `hpa` (CPU HPA) or `keda-hybrid` (queue depth + CPU via KEDA)                                                                                           | hpa                    |
| worker_autoscaling.keda.queueLengthPerWorker       | Queue items per worker target for KEDA Redis triggers                                                                                                                            | 80                     |
| worker_autoscaling.keda.activationQueueLength      | Minimum queue depth before KEDA begins scaling from idle/min state                                                                                                               | 1                      |
| worker_autoscaling.keda.queueNames                 | Redis queue names used for KEDA triggers (rendered as `resque:queue:<name>`)                                                                                                     | [simulations,requeued] |
| worker_autoscaling.keda.enableCpuTrigger           | Include CPU trigger alongside queue triggers in `keda-hybrid` mode                                                                                                               | false                  |
| autoscaler.expander                                | Cluster Autoscaler expander strategy (`least-waste`, `most-pods`, `random`, `priority`)                                                                                          | least-waste            |
| autoscaler.priorityExpander.enabled                | Render priority-expander ConfigMap for deterministic node-group selection (requires `autoscaler.expander=priority`)                                                              | false                  |
| prepull.additionalImages                           | Additional image references pre-pulled by prepull DaemonSet on each node                                                                                                         | []                     |
| worker.queues                                      | Comma-separated worker queues consumed by simulation workers. Include `requeued` to drain requeue backlog automatically.                                                         | simulations,requeued   |
| worker.topologySpread.enabled                      | Enable worker `topologySpreadConstraints` to reduce single-node worker concentration during ramps.                                                                               | false                  |
| worker.topologySpread.maxSkew                      | Max permitted worker pod skew across topology domains when topology spread is enabled.                                                                                           | 1                      |
| worker.topologySpread.topologyKey                  | Topology label key used for worker spread domains (for example hostname).                                                                                                        | kubernetes.io/hostname |
| worker.topologySpread.whenUnsatisfiable            | Scheduler behavior when ideal spread cannot be met (`DoNotSchedule` or `ScheduleAnyway`).                                                                                        | ScheduleAnyway         |
| worker.topologySpread.minDomains                   | Optional minimum eligible topology domains before strict spread enforcement (`null` disables).                                                                                   | null                   |
| worker.topologySpread.nodeAffinityPolicy           | Whether spread calculations honor pod node affinity (`Honor` or `Ignore`).                                                                                                       | Honor                  |
| worker.topologySpread.nodeTaintsPolicy             | Whether spread calculations include tainted nodes (`Honor` or `Ignore`).                                                                                                         | Ignore                 |
| redis.url                                          | Optional explicit Redis URI used for `REDIS_URL`; recommended when credentials contain URI-reserved characters                                                                   | ""                     |
| redis.config.maxclients                            | Redis max client connections passed to `redis-server --maxclients` (important for large worker/background fleets)                                                                | 20000                  |
| redis.config.tcpBacklog                            | Redis TCP backlog passed to `redis-server --tcp-backlog`                                                                                                                         | 511                    |
| redis.config.timeoutSeconds                        | Redis idle client timeout passed to `redis-server --timeout` (`0` disables timeout)                                                                                              | 0                      |
| load_balancer.annotations                          | Optional extra annotations map applied to the LoadBalancer Service                                                                                                               | {}                     |
| load_balancer.sourceRanges                         | Optional `loadBalancerSourceRanges` list; some OpenStack Octavia providers ignore this setting                                                                                   | []                     |
| web_background.replicas                            | Number of projects/analyses to run in parallel. **\*Note** Algorithmic runs are currently not supported to run in parallel. Keep default value of 1 for these types of analyses. | 1                      |
| web_background.workerCount                         | Number of Resque workers (`COUNT`) launched per web-background pod                                                                                                               | 6                      |
| web_background.container.startup.maxRetries        | Maximum retries when `start-web-background` exits during startup (for transient DB/Redis races)                                                                                  | 12                     |
| web_background.container.startup.retryDelaySeconds | Delay between web-background startup retries                                                                                                                                     | 10                     |
| worker.container.startup.maxRetries                | Maximum retries when `start-workers` exits during startup (for transient DB/Redis races)                                                                                         | 12                     |
| worker.container.startup.retryDelaySeconds         | Delay between worker startup retries                                                                                                                                             | 10                     |
| worker.container.preStop.enabled                   | Enables worker graceful drain preStop hook                                                                                                                                       | true                   |
| worker.container.preStop.signal                    | Signal sent to resque processes during preStop drain                                                                                                                             | "3"                    |
| worker.container.preStop.pollIntervalSeconds       | Polling interval while waiting for ruby/openstudio process drain                                                                                                                 | 30                     |
| worker.container.preStop.maxWaitSeconds            | Upper bound for worker preStop wait loop before allowing termination                                                                                                             | 5100                   |
| global.images.org                                  | Docker image organization/registry namespace for OpenStudio images                                                                                                               | nrel                   |
| global.images.registry                             | Optional registry host for OpenStudio images                                                                                                                                     | ""                     |
| global.images.repositoryPrefix                     | Optional path prefix between registry and org/repository                                                                                                                         | ""                     |
| global.images.serverRepository                     | Repository name used by web, web-background, and worker containers                                                                                                               | openstudio-server      |
| global.images.rserveRepository                     | Repository name used by rserve container                                                                                                                                         | openstudio-rserve      |
| global.images.tag                                  | Shared image tag used for both server and rserve repositories                                                                                                                    | 3.10.0                 |
| global.imagePullSecrets                            | Optional pod-level image pull secret names for chart workloads                                                                                                                   | []                     |
| serviceAccount.create                              | Create a dedicated workload ServiceAccount for chart Deployments                                                                                                                 | true                   |
| serviceAccount.name                                | Existing or created workload ServiceAccount name (auto-generated when create=true and empty)                                                                                     | ""                     |
| serviceAccount.imagePullSecrets                    | Optional image pull secret names attached to chart-created ServiceAccount                                                                                                        | []                     |
| web_background.container.image                     | Optional explicit override for web-background image. If omitted, chart uses global.images.\* defaults                                                                            | (derived)              |
| web.container.image                                | Optional explicit override for web image. If omitted, chart uses global.images.\* defaults                                                                                       | (derived)              |
| worker.container.image                             | Optional explicit override for worker image. If omitted, chart uses global.images.\* defaults                                                                                    | (derived)              |
| rserve.container.image                             | Optional explicit override for rserve image. If omitted, chart uses global.images.\* defaults                                                                                    | (derived)              |

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

### NFS Mount `No such file or directory` During Rollout

If pods fail mounting `nfs-pvc` with `mount.nfs ... No such file or directory`:

1. Confirm the NFS provisioner has exactly one active pod and no stale rollout replica:
   ```bash
   kubectl -n openstudio-server get deploy,rs,pods | grep nfs-server-provisioner
   ```
2. Ensure the provisioner deployment strategy is `Recreate` (single-replica + RWO backend):
   ```bash
   kubectl -n openstudio-server get deploy openstudio-server-nfs-server-provisioner \
     -o jsonpath='{.spec.strategy.type}{"\n"}'
   ```
3. Check provisioner logs for invalid export state (`No export entries found` / `/nonexistent`):
   ```bash
   kubectl -n openstudio-server logs deploy/openstudio-server-nfs-server-provisioner --tail=200
   ```
4. If Kubernetes API requests are intermittently returning `502 Bad Gateway`, treat this as a platform control-plane incident first. NFS export reconciliation depends on API availability.

### Reliability Preflight, Snapshot, and Helm Reconcile Automation

Use `scripts/openstudio-reliability` to standardize triage and recovery steps:

```bash
# Read-only reliability checks (recommended first step)
./scripts/openstudio-reliability --mode check

# Quiet-window ceiling probe (report-only: recommends advance/hold + next maxReplicas)
./scripts/openstudio-reliability --mode ceiling-probe \
  --quiet-window-seconds 900 \
  --quiet-interval-seconds 30 \
  --probe-step-replicas 50

# Capture queue/job snapshots before any mutation
./scripts/openstudio-reliability --mode snapshot \
  --snapshot-dir ./incident-snapshots/openstudio-server-$(date +%Y%m%d-%H%M%S)

# Collect a timed scale baseline (repeated snapshots + timeline TSV)
./scripts/openstudio-reliability --mode scale-baseline \
  --duration-seconds 1200 \
  --interval-seconds 30 \
  --snapshot-dir ./incident-snapshots/openstudio-server-scale-$(date +%Y%m%d-%H%M%S)

# Reconcile Helm only for managed-field conflict failures
./scripts/openstudio-reliability --mode reconcile-helm --apply --allow-chart-apply

# Recover stuck analyses (stale started jobs/datapoints; apply-gated)
./scripts/openstudio-reliability --mode recover-stuck --stale-minutes 70 --apply
```

Design notes:

- Script defaults to read-only mode.
- Mutating operations require explicit `--apply`.
- Ceiling probe mode is read-only and emits deterministic recommendation lines (`RECOMMENDATION=advance|hold`, `SUGGESTED_NEXT_MAX_REPLICAS=<n>`).
- Snapshot mode captures queue depths and app job status for incident auditability.
- Scale-baseline mode captures repeated snapshots plus `scale_timeline.tsv` (HPA/deployment replicas, node readiness, and queue depths) for scale-up latency decomposition.

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

### Quick Retrospective: Pull Failures and Low Effective Worker Concurrency

Recent incident pattern and proven response:

1. Symptom: desired worker replicas were high, but most worker/web pods were `ErrImagePull`/`ImagePullBackOff`.
2. Root cause: node runtime mirror/auth path failed (for example `.../azimuth/docker.io/...` with `401 UNAUTHORIZED`), so pods could not pull required images.
3. Secondary blocker: web init container image was not cached/pullable, preventing web readiness even after some worker recovery.
4. Throughput confusion: a worker pod can be `Running` with low CPU when blocked in datapoint initialization (for example waiting on receipt/lock state), so "pod up" is not sufficient to confirm progress.

Recommended fast checks:

```bash
kubectl -n openstudio-server get deploy worker -o wide
kubectl -n openstudio-server get pods -l app=worker --no-headers | awk '{print $3}' | sort | uniq -c
kubectl -n openstudio-server get events --sort-by=.lastTimestamp | tail -n 80
kubectl -n openstudio-server describe pod <failing-pod-name>
```

If mirror auth is broken, temporary mitigation is to use node-cached images and `IfNotPresent` while registry auth is corrected.

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

| Metric                                                                     | Warning             | Critical             | Rationale                                                   |
| -------------------------------------------------------------------------- | ------------------- | -------------------- | ----------------------------------------------------------- |
| NFS `/export` free space                                                   | `<20%`              | `<10%`               | Early detection before DB/asset write failures.             |
| NFS fill projection (time-to-full)                                         | `<7 days`           | `<2 days`            | Catch rapid growth even when free space still appears high. |
| Redis `resque:queue:simulations` backlog age                               | `>15m`              | `>30m`               | Detect worker throughput mismatch.                          |
| Queue/job divergence (`Job(status='queued')` with near-empty Redis queues) | `>5 queued for 10m` | `>20 queued for 10m` | Detect scheduler enqueue drift.                             |
| Worker HPA saturation (`current/target` CPU)                               | `>90% for 10m`      | `>95% for 15m`       | Detect sustained compute bottleneck.                        |
| Helm release state                                                         | `failed`            | `failed for >15m`    | Ensure operator metadata is reconciled quickly.             |

### Reliability Drill Cadence

Run a monthly drill that executes:

1. `./scripts/openstudio-reliability --mode check`
2. `./scripts/openstudio-reliability --mode snapshot --snapshot-dir <drill-artifacts>`
3. `./scripts/openstudio-reliability --mode scale-baseline --duration-seconds 600 --interval-seconds 30 --snapshot-dir <drill-artifacts>/scale-baseline`
4. Helm reconcile dry procedure review (no mutation), then controlled reconcile in non-prod.
5. Post-drill retrospective with action-item updates.

## Auto Scaling

Worker autoscaling supports two modes:

1. `worker_autoscaling.mode: hpa` (default): CPU-based Kubernetes HPA using `worker_hpa.*`.
2. `worker_autoscaling.mode: keda-hybrid`: KEDA `ScaledObject` with Redis queue depth triggers (`simulations`, `requeued` by default) plus CPU utilization trigger.

In both modes, scale bounds still come from `worker_hpa.minReplicas` and `worker_hpa.maxReplicas`, so existing capacity envelopes remain consistent.

For `keda-hybrid` mode:

- KEDA must be installed in the cluster.
- The chart creates a `TriggerAuthentication` that reads Redis password from the existing app secret.
- Queue signal tuning is controlled with `worker_autoscaling.keda.*`.

### Install KEDA (self-managed prerequisite)

Install KEDA once per cluster before enabling `worker_autoscaling.mode: keda-hybrid`.

1. Add/update the KEDA Helm repository:

```bash
helm repo add kedacore https://kedacore.github.io/charts
helm repo update
```

2. Install (or upgrade) KEDA in its own namespace:

```bash
helm upgrade --install keda kedacore/keda \
  --namespace keda \
  --create-namespace \
  --wait \
  --timeout 10m
```

3. Verify CRDs and operator health:

```bash
kubectl get crd scaledobjects.keda.sh triggerauthentications.keda.sh clustertriggerauthentications.keda.sh
kubectl -n keda get deploy,pods
```

Expected result: KEDA CRDs exist and `keda-operator`, `keda-operator-metrics-apiserver`, and `keda-admission-webhooks` are `Ready`/`Running`.

Optional lifecycle commands:

```bash
# Upgrade KEDA later
helm upgrade keda kedacore/keda -n keda --wait --timeout 10m

# Uninstall KEDA (only if no workloads depend on it)
helm uninstall keda -n keda
```

Worker termination remains drain-safe via the [preStop hook](https://kubernetes.io/docs/concepts/containers/container-lifecycle-hooks/) (`worker.container.preStop.*`) so scale-down does not abruptly kill long-running simulations.

### Scale-up SLOs (recommended)

Use these as baseline objectives for high-capacity clusters and adapt per environment:

- **Time to 25% of max worker replicas:** <= 5 minutes
- **Time to 50% of max worker replicas:** <= 10 minutes
- **Time to configured max worker replicas:** <= 20 minutes
- **Redis queue backlog age (`simulations`):** <= 15 minutes under sustained load

Track these during each scale test with `kubectl get hpa/scaledobject`, worker pod readiness, node readiness, and queue depth snapshots.

### Staged rollout sequence (recommended)

Roll out scaling changes in this order to isolate regressions:

1. Enable/verify observability first (`--mode scale-baseline`) and record baseline.
2. Apply autoscaling signal changes (`worker_autoscaling.mode`, KEDA tuning) in non-prod.
3. Apply node supply-side changes (`autoscaler.expander`, node groups, optional priority expander).
4. Run a controlled load test and compare timeline metrics to baseline.
5. Promote to production only after SLO and queue-age targets are met.

Rollback checkpoints:

- Autoscaling rollback: set `worker_autoscaling.mode=hpa` and redeploy.
- Node-strategy rollback: set `autoscaler.expander=least-waste` (or previous setting) and remove `priorityExpander` config.
- Full release rollback: `helm rollback <release> <revision> -n <namespace>`.

### Worker HPA scaling profiles

Three named profiles cover the main operational modes. Apply whichever matches your current
intent via `worker_hpa.behavior` in your values override. Always return to **stable** when
a ceiling probe returns `RECOMMENDATION=hold` or when any hazard signal is observed.

#### Profile comparison

| Profile    | Scale-up rate              | selectPolicy | Up stabilization | Down stabilization | Intended use                                            |
| ---------- | -------------------------- | ------------ | ---------------- | ------------------ | ------------------------------------------------------- |
| **stable** | 20 pods / 60 s             | Min          | 120 s            | 300 s              | Default steady-state; post-hold; incident window        |
| **ramp**   | 50 pods / 60 s             | Min          | 60 s             | 300 s              | Active ceiling discovery after `RECOMMENDATION=advance` |
| **burst**  | 100 pods/15 s + 100%/15 s  | Max          | 10 s             | 600 s              | Known-good cluster; confirmed large batch work          |

#### stable

Use for all normal operation and any time a gate check returns `hold`.

```yaml
worker_hpa:
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 120
      selectPolicy: Min
      policies:
        - type: Pods
          value: 20
          periodSeconds: 60
    scaleDown:
      stabilizationWindowSeconds: 300
      selectPolicy: Max
      policies:
        - type: Percent
          value: 15
          periodSeconds: 60
```

#### ramp

Use only after `scripts/openstudio-reliability --mode ceiling-probe` returns
`RECOMMENDATION=advance`. Increase `worker_hpa.maxReplicas` by one step at a time and
wait for readiness convergence before probing again. Return to **stable** immediately if
any blocker event appears.

Prerequisites:
- Ceiling probe passed with zero blocked samples in the observation window.
- All core services (`web`, `web-background`, `redis`, `rserve`) are Ready.
- No `FailedCreatePodSandBox`, `failed to sync secret cache`, or node pressure events.

```yaml
worker_hpa:
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 60
      selectPolicy: Min
      policies:
        - type: Pods
          value: 50
          periodSeconds: 60
    scaleDown:
      stabilizationWindowSeconds: 300
      selectPolicy: Max
      policies:
        - type: Percent
          value: 15
          periodSeconds: 60
```

#### burst

Use only when the cluster ceiling has been stable across multiple consecutive probe cycles
and a large confirmed batch requires maximum throughput. Do not use during ceiling
discovery or when any warning signals are present. Return to **stable** after the batch
completes or at the first sign of regression.

Prerequisites:
- Current `worker_hpa.maxReplicas` has been stable (no churn, no blockers) for at least
  two consecutive quiet-window probe cycles.
- No node pressure, OOM, or pod-sandbox events in recent history.
- Prepull DaemonSet healthy (all pods Ready) before scaling begins.

```yaml
worker_hpa:
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 10
      selectPolicy: Max
      policies:
        - type: Pods
          value: 100
          periodSeconds: 15
        - type: Percent
          value: 100
          periodSeconds: 15
    scaleDown:
      stabilizationWindowSeconds: 600
      selectPolicy: Max
      policies:
        - type: Percent
          value: 25
          periodSeconds: 60
```

#### Switching profiles

Apply a profile by adding `worker_hpa.behavior` to your local values override and running
`helm upgrade`:

```bash
helm upgrade openstudio-server ./openstudio-server \
  -n openstudio-server \
  --reuse-values \
  -f openstudio-server/values.registry-live.yaml \
  -f /path/to/your/profile-override.yaml
```

To revert to **stable** from any profile, apply the stable `worker_hpa.behavior` block
above and run `helm upgrade` with `--reuse-values`. The HPA will begin enforcing the
new policy within one polling cycle (typically under 30 seconds).
