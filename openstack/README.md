# OpenStack

Minimal notes for installing this chart on an already-existing OpenStack
Kubernetes cluster (e.g. one provisioned by [Azimuth](https://github.com/stackhpc/azimuth)).
This directory intentionally does not contain any tooling to create the
Kubernetes cluster itself (no Terraform/Kubespray/etc.) — use Azimuth (or
your own provisioning method) for that, then point `helm install` at the
resulting cluster.

## Prerequisites

- An existing Kubernetes cluster on OpenStack with the
  [Cinder CSI driver](https://github.com/kubernetes/cloud-provider-openstack/blob/master/docs/cinder-csi-plugin/using-cinder-csi-plugin.md)
  installed (this is what Azimuth-provisioned clusters ship by default).
- Node scheduling: `values-openstack.yaml` sets `node_group.label_key` to
  Azimuth's native Cluster API node-group label
  (`capi.stackhpc.com/node-group: web|worker`), so no manual node labeling
  is needed on Azimuth. On a different OpenStack cluster without that
  label, either label nodes `nodegroup=web-group` / `nodegroup=worker-group`
  yourself, or override `node_group.*` to match your cluster's own scheme
  (see `openstudio-server/values.yaml` for the full set of options).
- **The `nfs-server-provisioner` subchart is a separate vendored
  dependency and does NOT read `node_group.*`** — it has its own hardcoded
  default affinity. `values-openstack.yaml` overrides
  `nfs-server-provisioner.affinity` directly; if you change your node-group
  label scheme, update that override too or this pod will never schedule.

## Install

```bash
helm install openstudio-server ./openstudio-server -f openstack/values-openstack.yaml -n openstudio-server
```

See [`values-openstack.yaml`](./values-openstack.yaml) for the values this
sets, and the top-level [README](../README.md) for general chart install
instructions.

## Troubleshooting

- **`StorageClass "ssd" ... exists and cannot be imported into the current
  release: invalid ownership metadata`**: a `ssd` StorageClass from a
  previous/different release or namespace is still on the cluster. If
  nothing currently uses it (`kubectl get pvc -A -o
  jsonpath='{range .items[?(@.spec.storageClassName=="ssd")]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}'`),
  delete it (`kubectl delete storageclass ssd`) and re-run install — Helm
  will recreate it with the correct ownership.
- **`StorageClass ... reclaimPolicy: Forbidden` / `volumeBindingMode:
  ... field is immutable`**: same root cause as above — `reclaimPolicy`
  and `volumeBindingMode` can't be changed on an existing StorageClass.
  Delete and let Helm recreate it (same fix as above).
- **Helm v4 `conflict occurred while applying object ... with subresource
  "scale"`**: Helm v4 uses server-side apply by default. If a Deployment's
  `.spec.replicas` is currently owned by `kube-controller-manager` (via an
  active HPA, e.g. from a previous partially-failed install), Helm won't
  overwrite it without `--force-conflicts` on `helm upgrade --install`.
- If a previous `helm install`/`uninstall` didn't complete cleanly (e.g.
  pods stuck `Terminating` due to a container runtime issue), don't retry
  with a fresh `helm install` into the same failed release — use
  `helm upgrade --install ... --force-conflicts` to move it forward
  instead, after clearing any stuck pods
  (`kubectl delete pods --all -n <namespace> --grace-period=0 --force`).
