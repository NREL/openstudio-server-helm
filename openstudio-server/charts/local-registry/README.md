# Local Registry Subchart

This subchart deploys a local Docker registry (using `distribution/registry:2`) on Kubernetes for storing and serving container images within the cluster.

## Features

- Deploys a single-replica registry Deployment
- Configurable persistence via PVC
- ClusterIP Service (with NodePort option)
- ConfigMap-based registry configuration
- Security contexts for non-root operation

## Installation

This chart is designed to be used as a dependency of the `openstudio-server` chart. It is conditionally enabled via the parent chart's values:

```yaml
localRegistry:
  enabled: true
```

## Configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| `enabled` | Enable the local registry | `false` |
| `image` | Registry container image | `registry:2` |
| `imagePullPolicy` | Image pull policy | `IfNotPresent` |
| `resources` | Container resource limits/requests | `{}` |
| `persistence.enabled` | Enable persistent storage | `true` |
| `persistence.size` | PVC size | `10Gi` |
| `persistence.storageClass` | Storage class (empty for default) | `""` |
| `persistence.accessMode` | PVC access mode | `ReadWriteOnce` |
| `service.type` | Service type | `ClusterIP` |
| `service.port` | Service port | `5000` |
| `config` | Registry configuration (YAML) | See values.yaml |

## Registry Configuration

The registry is configured via a ConfigMap mounted at `/etc/docker/registry/config.yml`. The default configuration enables:

- JSON logging
- Filesystem storage at `/var/lib/registry`
- Delete API (for garbage collection)
- Health checks

See [distribution/distribution configuration docs](https://github.com/distribution/distribution/blob/main/docs/configuration.md) for all options.

## Usage with OpenStudio Server

When enabled in the parent chart with `localRegistry.rewriteImages: true`, all workload images (web, worker, db, redis, rserve, web-background, cluster-autoscaler, pre-delete hook) will be rewritten to pull from the local registry:

```
Original: nrel/openstudio-server:3.8.0-1
Rewritten: <release-name>-local-registry:5000/nrel/openstudio-server:3.8.0-1
```

### Pushing Images to Local Registry

After deploying the chart with the local registry enabled, you need to push your images to the registry:

```bash
# Get the registry service name (usually <release-name>-local-registry)
REGISTRY=$(kubectl get svc -n <namespace> -l app.kubernetes.io/name=local-registry -o jsonpath='{.items[0].metadata.name}')

# Port-forward to access locally
kubectl port-forward -n <namespace> svc/$REGISTRY 5000:5000

# In another terminal, tag and push images
docker pull nrel/openstudio-server:3.8.0-1
docker tag nrel/openstudio-server:3.8.0-1 localhost:5000/nrel/openstudio-server:3.8.0-1
docker push localhost:5000/nrel/openstudio-server:3.8.0-1

# Repeat for all required images:
# - nrel/openstudio-server:3.8.0-1
# - nrel/openstudio-rserve:3.8.0-1
# - mongo:6.0.7
# - redis:6.0.9
# - bitnami/kubectl:latest (for pre-delete hook)
# - registry.k8s.io/autoscaling/cluster-autoscaler:v1.26.6
```

### Using External Registry

To use an external registry instead of deploying the subchart:

```yaml
localRegistry:
  enabled: false  # Don't deploy subchart
  hostname: "my-registry.internal"  # External registry hostname
  port: 5000
  rewriteImages: true  # Still rewrite image references
```

## Verification

Check that the registry is running:

```bash
kubectl get pods -n <namespace> -l app.kubernetes.io/name=local-registry
kubectl logs -n <namespace> -l app.kubernetes.io/name=local-registry
```

Test the registry API:

```bash
kubectl port-forward -n <namespace> svc/<release-name>-local-registry 5000:5000
curl http://localhost:5000/v2/_catalog
```

## Troubleshooting

- **ImagePullBackOff**: Ensure images have been pushed to the local registry
- **PVC Pending**: Check storage class availability and permissions
- **Registry not ready**: The cluster-autoscaler has an initContainer that waits for the registry; check its logs if autoscaler pods are stuck in Init state