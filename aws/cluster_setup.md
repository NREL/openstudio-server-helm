# AWS EKS Setup: Spot Workers and On-Demand Essential Pods

This guide documents how to create an EKS cluster where:

- Essential OpenStudio Server pods run on regular (on-demand) instances.
- Worker pods run on spot instances.
- Required EKS add-ons are installed during initial setup: Amazon EBS CSI Driver, Amazon VPC CNI, and kube-proxy.

This configuration is intended for large workloads where you want lower worker cost while keeping core services stable for NFS-backed workflows.

## 1. Prerequisites

- AWS account permissions for EKS, EC2, IAM, and CloudFormation
- `aws` CLI configured (`aws configure`)
- `eksctl` v1.40.0+
- `kubectl` compatible with your target cluster version
- `helm` v3.12+

Optional but recommended before large clusters:

- Request EC2 quota increases for both On-Demand and Spot instance families you plan to use.

### 1.1 Quota sizing for 10,000 worker pods

For AWS, the key EC2 quota for the worker node groups in this guide is:

- `All Standard (A, C, D, H, I, M, R, T, Z) Spot Instance Requests` (regional, in vCPUs)

If your worker pod request is `1 vCPU` (as used in the large workload template), the minimum worker compute is:

- Required worker vCPU = `10,000 pods * 1 vCPU` = `10,000 vCPU`

Using the worker instance types in this repo (for example `c7i.48xlarge` / `c7a.48xlarge` at 192 vCPU each):

- Minimum spot nodes = `ceil(10,000 / 192)` = `53 nodes`

You should add headroom for:

- Kubernetes/system daemons
- Spot interruption replacement
- Bin-packing inefficiency during scale transitions

Recommended request target (20% headroom):

- Spot vCPU quota target = `10,000 * 1.2` = `12,000 vCPU`
- Spot node target at 192 vCPU/node = `ceil(12,000 / 192)` = `63 nodes`

On-demand quota for essential services depends on web-group sizing. With one `m7i.8xlarge` essential node:

- On-demand vCPU = `32 vCPU`

Recommended on-demand target with failover/headroom:

- `64 vCPU` (2 x `m7i.8xlarge`) minimum practical target
- `96 vCPU` if you want more maintenance/failure margin

If you tune worker CPU requests, use this formula:

- Spot vCPU quota target = `worker_pod_count * worker_cpu_request * headroom_factor`

Example with `500m` workers and 20% headroom:

- `10,000 * 0.5 * 1.2 = 6,000 vCPU`

Important: quota alone is not enough at this scale. You must also ensure subnet IP capacity for VPC CNI (or enable prefix delegation) so nodes can host the required pod density.

## 2. Recommended Node Group Pattern

Use separate managed node groups and labels:

- On-demand node group for essential pods: label `nodegroup=web-group`
- Spot node groups for workers: label `nodegroup=worker-group`

The chart templates in this repo already use node affinity for this pattern:

- Essential services (web, db, redis, rserve, web-background, autoscaler, nfs provisioner) target `web-group`.
- Worker deployment targets `worker-group`.

## 3. Cluster Config Requirements (eksctl)

Use [eks_config_large-spot.yaml](../eks_config_large-spot.yaml) as your base. Ensure these key settings are present.

### 3.1 OIDC and EBS CSI IAM setup

```yaml
iam:
  withOIDC: true
  serviceAccounts:
    - metadata:
        name: ebs-csi-controller-sa
        namespace: kube-system
      wellKnownPolicies:
        ebsCSIController: true
```

### 3.2 On-demand essential node group

```yaml
managedNodeGroups:
  - name: Web-node-group2
    instanceType: m7i.8xlarge
    minSize: 0
    maxSize: 1
    desiredCapacity: 1
    labels:
      nodegroup: web-group
      role: essential
    tags:
      node-role: essential
```

### 3.3 Spot worker node groups

```yaml
managedNodeGroups:
  - name: worker-node-group-spot-2a
    spot: true
    instanceTypes: ["c7i.48xlarge", "c7a.48xlarge", "c7i.metal-48xl", "c7a.metal-48xl"]
    minSize: 0
    maxSize: 10
    desiredCapacity: 0
    labels:
      nodegroup: worker-group
      role: worker
    tags:
      node-role: worker
      capacity-type: spot
```

Repeat spot worker node groups across multiple subnets/AZs for availability.

### 3.4 Subnet planning for ITS-provided subnets

This cluster uses private subnets provided internally by the ITS organization.

Key points:

- You can assign multiple subnets to a node group.
- ITS subnets are currently `/25`, which provides `126` usable IPs per subnet.
- Smaller VM instance types can exhaust subnet IPs faster because you need more nodes to deliver the same total compute.
- Larger instance types reduce node count and helped avoid IP exhaustion in prior runs.

Operational guidance:

- Spread worker node groups across multiple subnets (and AZs where possible).
- Monitor subnet free IPs during scale tests before production runs.
- If worker scale-out stalls, check subnet IP availability before assuming EC2 capacity shortage.

Roadmap note:

- ITS is working on enabling additional non-routable private IP space. Follow up with the AWS Status team for rollout timing.

### 3.5 Required EKS add-ons at cluster creation

Add this `addons` section (or verify it exists):

```yaml
addons:
  - name: vpc-cni
    mostRecent: true
  - name: kube-proxy
    mostRecent: true
  - name: aws-ebs-csi-driver
    wellKnownPolicies:
      ebsCSIController: true
```

Note:

- `vpc-cni` is required for pod networking/IP assignment.
- `kube-proxy` is required for Kubernetes service networking.
- `aws-ebs-csi-driver` is required for dynamic EBS-backed PVC provisioning used by the deployment.

## 4. Create the Cluster

From the repo root:

```bash
eksctl create cluster -f eks_config_large-spot.yaml
```

## 5. Verify Node Groups, Labels, and Capacity Type

Check node groups:

```bash
eksctl get nodegroup --cluster openstudio-server-03 --region us-west-2
```

Check node labels and spot vs on-demand capacity:

```bash
kubectl get nodes -L nodegroup,eks.amazonaws.com/capacityType
```

Expected result:

- Essential node(s): `nodegroup=web-group`, typically `ON_DEMAND`
- Worker node(s): `nodegroup=worker-group`, typically `SPOT`

## 6. Verify Required Add-ons

```bash
aws eks describe-addon --cluster-name openstudio-server-03 --addon-name vpc-cni --region us-west-2 --query 'addon.status'
aws eks describe-addon --cluster-name openstudio-server-03 --addon-name kube-proxy --region us-west-2 --query 'addon.status'
aws eks describe-addon --cluster-name openstudio-server-03 --addon-name aws-ebs-csi-driver --region us-west-2 --query 'addon.status'
```

Each command should return `"ACTIVE"`.


## 7. Operational Recommendations

- Keep at least one on-demand essential node available (`desiredCapacity >= 1`) to avoid core service disruption.
- Use multiple spot worker node groups across AZs/subnets for resilience and better spot capacity.
- Keep `worker_hpa` aligned with max spot node capacity in your cluster config.

## 8. Add Auto Scaling Launch Lifecycle Hooks (Optional)

If you need a short pause during node launch (for warm-up checks or custom automation), add an Auto Scaling lifecycle hook to each worker node group ASG.

Important notes:

- EKS managed node groups own their ASGs. During updates or replacements, ASG names can change.
- Re-check ASG names after node group updates and re-apply hooks if needed.
- With `--default-result CONTINUE`, the instance launch proceeds even if no external process sends lifecycle completion.

Get the ASG name for a managed node group:

```bash
aws eks describe-nodegroup \
  --cluster-name openstudio-server-03 \
  --nodegroup-name worker-node-group-spot-2c \
  --region us-west-2 \
  --profile developers-554977624503 \
  --query 'nodegroup.resources.autoScalingGroups[0].name' \
  --output text
```

Add the launch lifecycle hook (example):

```bash
aws autoscaling put-lifecycle-hook \
  --lifecycle-hook-name Launch-LC-Hook \
  --auto-scaling-group-name eks-worker-node-group-spot-02-56c8852f-5f77-b3c0-3a70-ede003827aaa \
  --lifecycle-transition autoscaling:EC2_INSTANCE_LAUNCHING \
  --role-arn arn:aws:iam::554977624503:role/aws-service-role/autoscaling.amazonaws.com/AWSServiceRoleForAutoScaling \
  --heartbeat-timeout 30 \
  --default-result CONTINUE \
  --profile developers-554977624503
```

Verify hooks on the ASG:

```bash
aws autoscaling describe-lifecycle-hooks \
  --auto-scaling-group-name eks-worker-node-group-spot-02-56c8852f-5f77-b3c0-3a70-ede003827aaa \
  --profile developers-554977624503
```

Repeat for each worker node group ASG you want to control.

## 9. Example: Scale a Spot Worker Node Group

Use `eksctl scale nodegroup` to quickly adjust a worker group.

```bash
eksctl scale nodegroup --cluster openstudio-server-03 --name worker-node-group-spot-2c --nodes 1 --nodes-max 9 --nodes-min 0 --region us-west-2 --profile developers-554977624503
```

What this does:

- Sets desired nodes to `1`
- Sets autoscaler floor to `0`
- Sets autoscaler ceiling to `9`

Verify the updated node group settings:

```bash
eksctl get nodegroup --cluster openstudio-server-03 --region us-west-2 --profile developers-554977624503
```

Verify worker nodes become available:

```bash
kubectl get nodes -L nodegroup,eks.amazonaws.com/capacityType
```
## 10. Deploy OpenStudio Server Chart

```bash
helm install openstudio-server ./openstudio-server --set provider.name=aws
```

## 11. Verify Essential vs Worker Pod Placement

```bash
kubectl get pods -o wide
```

Confirm:

- `web`, `web-background`, `db`, `redis`, `rserve`, and `nfs-server-provisioner` are on `web-group` nodes.
- `worker-*` pods are on `worker-group` spot nodes.

## 12. NFS and Storage Notes

- NFS server and core services should remain on on-demand `web-group` nodes.
- Worker interruption on Spot should not take down the core web/db/nfs path.
- If PVC provisioning fails, verify EBS CSI add-on is `ACTIVE` and the IAM OIDC/service account setup is present.


## 13. Scale worker pods

When scaling worker capacity during active analyses, prefer patching the worker HPA rather than running `helm upgrade` for this specific change. This avoids unnecessary deployment churn while jobs are running.

Example: set worker HPA max replicas to `2000`.

```bash
kubectl patch hpa worker -n default --type='json' -p='[{"op": "replace", "path": "/spec/maxReplicas", "value": 2000}]'
```

You can also update the HPA minimum if needed:

```bash
kubectl patch hpa worker -n default --type='json' -p='[{"op": "replace", "path": "/spec/minReplicas", "value": 1}]'
```

Important note about max pods per node:

- `maxPodsPerNode` is an EKS node group/launch configuration setting, not a Kubernetes resource you can patch with `kubectl`.
- Plan this value in your node group configuration before provisioning or when updating/replacing the node group.
- This matters at high scale because pod density per node and subnet IP limits both affect how far worker pods can scale.


## 14. Tear down

To remove everything, first remove the helm chart as this deletes resources used by helm/k8s such as persistent volumes. If you just remove the EKS cluster, these will remain and will be billed.

helm delete openstudio-server ./openstudio-server --set provider.name=aws 

Confirm deletion and check if all pods are removed 

# show all
kubectl get all --all-namespaces 
# show the persistent volumes 
kubectl get pv

When you confirm openstudio-server 




## 15. Troubleshooting and FAQ

Many core Kubernetes services run as pods in the `kube-system` namespace. These are often the first place to check when node networking, scaling, or add-on behavior is not as expected.

List all `kube-system` pods:

```bash
get pod -n kube-system --show-labels
```

Check logs for service using labels example:

```bash
kubectl get logs -l app=ebs-csi-controller, -n kube-system
```

Useful follow-up checks:

```bash
kubectl describe pod -n kube-system aws-node-csx9h
aws eks describe-addon --cluster-name openstudio-server-03 --addon-name vpc-cni --region us-west-2 --query 'addon.status'
```


