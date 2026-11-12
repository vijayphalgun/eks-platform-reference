# Design notes

Why the platform is built the way it is, and which production failure modes each choice is meant to prevent.

## Compute: a small system node group plus Karpenter

**Decision.** One managed node group of two nodes runs only cluster-critical add-ons (Karpenter, CoreDNS, metrics-server). It carries a `CriticalAddonsOnly` taint. All application capacity comes from a Karpenter NodePool.

**Why.** Karpenter can't schedule the pods that run Karpenter. Putting the controller on nodes it manages risks a deadlock: during consolidation, Karpenter can drain the node it's running on and leave nothing able to launch replacements. A tainted system group gives the control-plane add-ons a stable home that application spikes can't crowd out.

**Trade-off.** Two always-on nodes cost money even when idle. For a production platform that's cheap insurance; for a short-lived demo, Fargate for the Karpenter controller is an alternative.

## Karpenter discovery depends on tags, and missing tags fail quietly

Karpenter finds subnets and security groups by the `karpenter.sh/discovery` tag. Both are set in Terraform: on the private subnets in the VPC module, and on the node security group in the EKS module.

A missing tag doesn't produce an obvious error. Instances launch, but they either land in the wrong network or can't reach the control plane, so they show up as `NodeNotFound` or never become `Ready`. When nodes launch but never join, check the EC2NodeClass selectors against the actual tags first.

## Disruption is budgeted

The NodePool consolidates underused nodes, expires every node after 30 days so they pick up patched AMIs, and limits voluntary disruption to 20% of nodes at a time. The sample app pairs that with a PodDisruptionBudget (`minAvailable: 2`) and zone-then-node topology spread, so consolidation and node expiry never take down every replica at once.

Spot interruptions arrive through the SQS queue the Karpenter module creates. Karpenter cordons and drains the affected node during the two-minute warning instead of losing pods abruptly.

## Identity: access entries and Pod Identity

- **Cluster access** uses EKS access entries rather than the `aws-auth` ConfigMap, so access is managed through the EKS API and Terraform. A bad edit can't lock everyone out.
- **Workload AWS access** uses EKS Pod Identity. Karpenter gets its controller permissions and Fluent Bit gets `s3:PutObject` on one bucket. Nothing is granted to the node role that every pod on the node would inherit.
- **IMDSv2 with a hop limit of 1** on Karpenter nodes stops pods from reaching the instance metadata service and borrowing the node's credentials.

## Stateful components need a stable identity

The platform itself is mostly stateless, but the same rule applies to anything clustered that you run on it, such as message brokers, databases or blockchain nodes. A clustered stateful system run as a Deployment gets random pod names and no stable network identity. On restart, members can fail to find each other and form separate clusters (a split-brain). Use a StatefulSet with a headless Service, persistent volumes per replica, and a quorum-based replication mode, and test what happens when a member restarts.

## Logging: one pipeline, environment-specific outputs

Fluent Bit's input, parsing and enrichment live in the Kustomize base. Each overlay replaces only `output.conf`: stdout locally, S3 on AWS. The pipeline you test on a laptop is the pipeline that runs in the cluster.

Multiline parsing matters more than it looks. Without it, every line of a stack trace becomes a separate record, so searches and alerts match fragments instead of the whole event. The base applies the built-in Java, Python and Go parsers plus a timestamp-anchored parser for services (such as .NET and Node) that start each log entry with a timestamp.

Tail offsets are kept on the host (`/var/fluent-bit/state`), so a Fluent Bit restart neither re-ships nor skips logs.

## Teardown order

Terraform doesn't track the instances Karpenter launches. Running `terraform destroy` while those instances exist leaves their network interfaces attached to the subnets, and the VPC deletion fails partway through. `Teardown.ps1` deletes the NodePool, waits for Karpenter's nodes to terminate, and only then destroys the infrastructure.

## What I'd add for production

- Remote state in S3 with native locking (the commented `backend "s3"` block in `versions.tf`)
- A NAT gateway per AZ (`single_nat_gateway = false`) so egress survives an AZ outage
- A private API endpoint, reached through a VPN or bastion
- Ingress through the AWS Load Balancer Controller with TLS from ACM
- Prometheus and Grafana (or Amazon Managed Prometheus), with SLO-based alerts on the sample app
- Policy enforcement (Kyverno or Gatekeeper) to require resource requests, non-root containers and approved registries
- GitOps (Argo CD or Flux) to reconcile the Kubernetes layer from Git
