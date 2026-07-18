# KEDA external scaler starter (worker readiness gate)

This service implements KEDA's gRPC external scaler API and adds a readiness gate for worker scale-up:

- It reads Redis queue depth (`resque:queue:*`).
- It reads worker Deployment `readyReplicas/spec.replicas`.
- It blocks further scale-up when ready percentage is below `READY_GATE_MIN_PERCENT` (default `95`).

## Build and push

```bash
cd tools/keda-external-scaler
docker build -t <registry>/<repo>/openstudio-keda-external-scaler:latest .
docker push <registry>/<repo>/openstudio-keda-external-scaler:latest
```

If Pulp/registry is unavailable, stop after `docker build` and retry push/deploy later with:

```bash
# 1) authenticate when registry is healthy again
docker login pulp-dev.hpc.nlr.gov

# 2) retag to a writable repo path
docker tag pulp-dev.hpc.nlr.gov/pulp-container-aurora-179d/nrel/openstudio-keda-external-scaler:latest \
  pulp-dev.hpc.nlr.gov/pulp-container-aurora-179d/<your-namespace>/openstudio-keda-external-scaler:latest

# 3) push
docker push pulp-dev.hpc.nlr.gov/pulp-container-aurora-179d/<your-namespace>/openstudio-keda-external-scaler:latest
```

## Enable in chart

Use both overlays:

```bash
helm upgrade --install openstudio-server ./openstudio-server \
  -n openstudio-server \
  -f openstack/values-openstack-azimuth.yaml \
  -f openstack/values-openstack-azimuth-external-scaler.yaml \
  --set secrets.validateExistingSecret=false
```

Set image in `openstack/values-openstack-azimuth-external-scaler.yaml`:

```yaml
worker_autoscaling:
  keda:
    externalScaler:
      deployment:
        image: "<registry>/<repo>/openstudio-keda-external-scaler:latest"
```

Or keep the overlay as-is and override image at deploy time:

```bash
helm upgrade --install openstudio-server ./openstudio-server \
  -n openstudio-server --create-namespace \
  -f openstack/values-openstack-azimuth.yaml \
  -f openstack/values-openstack-azimuth-external-scaler.yaml \
  --set worker_autoscaling.keda.externalScaler.deployment.image=pulp-dev.hpc.nlr.gov/pulp-container-aurora-179d/<your-namespace>/openstudio-keda-external-scaler:latest
```
