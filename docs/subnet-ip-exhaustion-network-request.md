# Request: carve new subnets from the unused `100.64.0.0/16` VPC CIDR to fix worker-node IP exhaustion

**Date:** 2026-08-20
**Cluster:** `openstudio-server-03` (EKS, `us-west-2`)
**VPC:** `vpc-058a510d64a96f2d5` (tagged `landing-zone-vpc`)
**Requested by:** platform/on-call (blocked by org guardrail, see below)
**Status:** blocked -- needs someone with elevated/exception access to run `ec2:CreateSubnet` on this VPC

## Summary

During a worker-pod scale-up incident (HPA target 10,000 replicas, stalled around
4,300-7,700 actual), we traced part of the shortfall to per-AZ subnet IP
exhaustion in `us-west-2a`, `us-west-2b`, and `us-west-2d`. The `aws-cni` plugin
was failing pod-sandbox creation with `failed to assign an IP address to
container` on nodes in those AZs, which cascaded into stuck DaemonSet pods,
untainted-but-unusable nodes, and wasted cluster-autoscaler scale-up attempts.

While investigating, we found the VPC already has a **second, completely unused
CIDR block, `100.64.0.0/16` (65,536 addresses), associated but with zero
subnets carved out of it**. This is a much larger, already-available pool than
anything we'd need to request from scratch -- we just need subnets created in
it and wired up.

**We cannot do this ourselves.** Attempting `aws ec2 create-subnet` on this VPC
returns an explicit deny from an org-level SCP:

```
An error occurred (UnauthorizedOperation) when calling the CreateSubnet operation:
... is not authorized to perform: ec2:CreateSubnet on resource:
arn:aws:ec2:us-west-2:554977624503:vpc/vpc-058a510d64a96f2d5
with an explicit deny in an identity-based policy.
```

Decoding the authorization failure message (`aws sts decode-authorization-message`)
identifies the blocking statement:

```
"statementId": "DenyNetworkModifications"
"effect": "DENY"
"action": "CreateSubnet"
"resource": "arn:aws:ec2:us-west-2:554977624503:vpc/vpc-058a510d64a96f2d5"
```

This is a deliberate landing-zone guardrail, not a missing IAM permission -- we
need either an SCP exception or someone with sufficient access to create these
subnets on our behalf.

## Current IP picture (existing subnets only, before this request)

| AZ | Free IPs (existing subnets) |
|---|---|
| us-west-2a | 548 |
| us-west-2b | 243 |
| us-west-2c | 5,790 |
| us-west-2d | 148 |

2a/2b/2d are the AZs starving our worker autoscaler groups; 2c already has
ample headroom (it's where we've been steering all scale-up as a workaround).

## Exact ask

Carve three new subnets out of the VPC's existing `100.64.0.0/16` CIDR
(already associated with the VPC -- no new CIDR association needed), one per
starved AZ, each large enough to meaningfully fix the shortage:

| AZ | Proposed CIDR | Size | Proposed subnet name tag |
|---|---|---|---|
| us-west-2a | `100.64.0.0/20` | 4,096 IPs | `private-2a-100-64` |
| us-west-2b | `100.64.16.0/20` | 4,096 IPs | `private-2b-100-64` |
| us-west-2d | `100.64.32.0/20` | 4,096 IPs | `private-2d-100-64` |

(`/20` sizing leaves the rest of `100.64.0.0/16` free for future AZs/growth;
happy to adjust sizing if there's a reason to go bigger/smaller.)

Suggested tags on each subnet (matching existing subnet tagging convention in
this VPC):
```
Name=<per table above>
kubernetes.io/cluster/openstudio-server-03=shared
kubernetes.io/role/internal-elb=1
```

## Route table association (no new NAT gateway needed)

We confirmed the VPC's existing private route tables already have working NAT
egress and are each shared across multiple subnets/AZs already -- new subnets
just need to be associated with the existing table for their AZ, reusing the
same NAT gateway (`nat-063e771c4fe98fcc9`, in subnet `subnet-021782aa86f26f1d4`):

| AZ | Existing route table to associate with | Already serves |
|---|---|---|
| us-west-2a | `rtb-0866079a821141c41` | subnet-08a05df026b4ec9a8, subnet-02213ae644f5f392e, subnet-099feb77ea09bd101, subnet-00ea3f10afdc9fb8e |
| us-west-2b | `rtb-00e99a3d9e312f767` | subnet-0e099ff201ece82b3 |
| us-west-2d | `rtb-0d49fe6474b5d8683` | subnet-0027c0fd03f5cb2bb, subnet-081506cc8b6d3dbb2, subnet-04bbcd385d4d482cc |

**Caveat worth flagging:** there is currently only **one** NAT gateway for the
whole VPC. Adding meaningfully more traffic through 2a/2b/2d increases load on
that single NAT gateway. Not a blocker to proceed, but worth monitoring
(NAT gateway bandwidth/connection-count metrics) once these subnets are in use,
and potentially worth a follow-up to add per-AZ NAT gateways if it becomes a
bottleneck.

## Known follow-up needed on our side (informational, no action needed from network team)

The EKS cluster's control-plane `resourcesVpcConfig.subnetIds` is fixed at
cluster-creation time to a specific AZ set (currently 2a/2b only) and AWS
refuses `update-cluster-config` additions outside that set:

```
Provided subnets belong to the AZs 'us-west-2a,us-west-2b,us-west-2c'.
But they should belong to the exact set of AZs 'us-west-2a,us-west-2b'
in which subnets were provided during cluster creation.
```

- New subnets in **2a/2b** are already within the cluster's allowed AZ set, so
  once created they should work immediately with `eksctl create nodegroup -f
  <config>` (the normal, file-driven flow).
- A new subnet in **2d** will likely hit the same AZ-validation quirk we
  already worked around for `us-west-2c` (which also isn't in the cluster's
  original AZ set) -- we'll use the direct-flag `eksctl create nodegroup
  --subnet-ids=...` form instead of `-f <file>` for that one. This is on us,
  not something the network team needs to solve.

## Impact once done

Relieves the root cause of a recurring worker-pod scheduling failure mode:
`aws-cni` unable to assign pod IPs on 2a/2b/2d, which was blocking a DaemonSet
that removes a scheduling taint from new nodes, in turn leaving nodes
unusable for the worker HPA (target 10,000 replicas) and wasting
cluster-autoscaler scale-up cycles on AZs that can't actually accept new pods.

## 2026-08-21 update: subnets created, node groups deployed

The three subnets were created and confirmed present in
`vpc-058a510d64a96f2d5`:

| AZ | Subnet name | Subnet ID | CIDR |
|---|---|---|---|
| us-west-2a | `private-2a-100-64` | `subnet-02f7305f11fada38b` | `100.64.0.0/20` |
| us-west-2b | `private-2b-100-64` | `subnet-0c935c8acff2810b6` | `100.64.16.0/20` |
| us-west-2d | `private-2d-100-64` | `subnet-01ccbeba4e7db32df` | `100.64.32.0/20` |

**Route table correction:** the table in the "Route table association" section
above was stale/incorrect for us-west-2b. `rtb-00e99a3d9e312f767` (originally
listed for 2b) is actually associated with `subnet-0e099ff201ece82b3`
(`landing-zone-public-subnet-2`, a **public** subnet routed via the internet
gateway `igw-04fc82a9a5e23ca6c`, not the NAT gateway) -- associating a new
private worker subnet with it would have made the subnet effectively public.
The actual private/NAT-routed route table already serving us-west-2b (via
`subnet-081506cc8b6d3dbb2`) is `rtb-0d49fe6474b5d8683`, which also already
serves us-west-2d. Final associations made (via `aws ec2
associate-route-table`, all via NAT gateway `nat-063e771c4fe98fcc9`):

| Subnet | Route table associated |
|---|---|
| `private-2a-100-64` (`subnet-02f7305f11fada38b`) | `rtb-0866079a821141c41` |
| `private-2b-100-64` (`subnet-0c935c8acff2810b6`) | `rtb-0d49fe6474b5d8683` |
| `private-2d-100-64` (`subnet-01ccbeba4e7db32df`) | `rtb-0d49fe6474b5d8683` |

**Node groups:** three new managed spot worker node groups were created (see
`eks_config_worker-100-64.yaml`), one per new subnet, using `subnets:`
(explicit subnet ID) rather than `availabilityZones:` in each nodegroup so
eksctl targets the new subnet specifically rather than re-resolving the AZ
name to an existing (still-starved) subnet. This also confirmed the
predicted AZ-validation quirk for us-west-2d does **not** apply when an
explicit subnet ID is given -- `eksctl create nodegroup -f
eks_config_worker-100-64.yaml` created all three (2a/2b/2d) in one pass with
no special-casing needed:

- `worker-node-group-spot-2a-100-64`
- `worker-node-group-spot-2b-100-64`
- `worker-node-group-spot-2d-100-64`

All three are `ACTIVE`, min/max 0/200, `desiredCapacity: 0` (scale-up is
left to cluster-autoscaler, same as the existing `-spot-2a/2c/2d` groups).
Verified end-to-end by scaling `worker-node-group-spot-2a-100-64` to 1 node:
it launched in the `100.64.0.0/20` subnet, joined the cluster
(`ip-100-64-2-67.us-west-2.compute.internal`), passed the
`prepull-needed` taint removal, and went `Ready` within ~30s -- confirming
aws-cni pod-IP assignment and NAT egress both work correctly on the new
subnet. Scaled back to 0 afterward.
