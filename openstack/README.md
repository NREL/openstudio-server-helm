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
- Nodes labeled `nodegroup=web-group` / `nodegroup=worker-group` as expected
  by this chart's pod scheduling (see `openstudio-server/templates/*/*-deploy.yaml`).

## Install

```bash
helm install openstudio-server ./openstudio-server -f openstack/values-openstack.yaml
```

See [`values-openstack.yaml`](./values-openstack.yaml) for the values this
sets, and the top-level [README](../README.md) for general chart install
instructions.
