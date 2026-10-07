# EKS Readiness Gaps and Solutions

This guide maps the gaps identified in the current Terraform configuration to practical ways to address them. It explains why each matters and when it is useful. It is a planning guide; it does not modify the Terraform configuration.

## Current Baseline

The current stack creates a VPC, public and private subnets in two Availability Zones, one NAT Gateway per AZ, an EKS control plane, and a managed node group. It has baseline IAM roles and policies for EKS and EC2 worker nodes. The selected Kubernetes version is configured as `1.36`.

The configuration has passed `terraform validate`, but that does not prove that AWS will accept an apply, that account permissions or quotas are sufficient, or that the workloads will run correctly.

## Priority Solutions

### 1. Restrict access to the Kubernetes API

**Current gap:** The EKS public API endpoint is enabled, but no public source CIDRs are specified. That leaves the endpoint reachable from any internet address, subject to authentication.

**Solution:** Choose one of these approaches:

- Keep public access and allow only the office, VPN, or CI runner's stable public CIDR ranges.
- Disable public access and require administrators and automation to connect from the VPC, VPN, or another connected network.
- Enable both private and restricted public access if teams need both paths.

For a restricted public endpoint, add a root input and pass it into the EKS module:

```hcl
variable "cluster_public_access_cidrs" {
  description = "Trusted IPv4 CIDRs allowed to reach the EKS public API endpoint."
  type        = list(string)
}
```

In the EKS module, use it in the existing `vpc_config` block:

```hcl
vpc_config {
  subnet_ids              = var.private_subnet_ids
  endpoint_private_access = true
  endpoint_public_access  = true
  public_access_cidrs     = var.cluster_public_access_cidrs
}
```

Pass the variable through the root module call, and set actual trusted ranges in your environment-specific Terraform inputs, for example `198.51.100.24/32` as a documentation-only example. Replace that example with your real VPN or administrator egress CIDR. Do not use `0.0.0.0/0` for a staging or production-like environment.

**Why it matters:** Anyone can reach a publicly exposed endpoint to attempt authentication. An IP allowlist reduces who can even connect to the API.

**Use it when:** Always for shared staging, QA, and pre-production. Private-only access is a good option if your operators and CI runners have reliable private network connectivity.

### 2. Configure administrator and deployment access

**Current gap:** The Terraform creates the cluster but does not create EKS access entries or Kubernetes RBAC for a team or deployment pipeline. AWS IAM permissions to create a cluster are separate from permission to administer Kubernetes objects inside it.

**Solution:** Use EKS access entries to grant named IAM roles access, then grant only the required EKS access policy or Kubernetes RBAC permissions. For example, a cluster administrator role can be represented like this:

```hcl
resource "aws_eks_access_entry" "admin" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = var.admin_role_arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "admin" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_eks_access_entry.admin.principal_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }
}
```

Define `admin_role_arn` as an input and use an IAM role assumed through your organization’s identity provider or CI system. Create a separate, more limited role for deployment automation rather than giving the pipeline broad administrator access. EKS access entries require the cluster authentication mode to include the EKS API (`API` or `API_AND_CONFIG_MAP`). If this is an existing cluster, review the migration implications before changing authentication mode.

**Why it matters:** Without an intentional access plan, administrators may be locked out, or automation may be given excessive permissions.

**Use it when:** Any cluster shared by more than one person or used by CI/CD. Use namespace-scoped Kubernetes roles for teams that only need to deploy to their own applications.

### 3. Manage EKS add-ons and their versions

**Current gap:** The configuration does not declare EKS add-ons. EKS may provide some add-ons or components as part of cluster/node setup, but this Terraform does not explicitly manage their versions or lifecycle.

**Solution:** Manage the core add-ons using Terraform `aws_eks_addon` resources: `vpc-cni`, `coredns`, and `kube-proxy`. Select versions compatible with the chosen Kubernetes version and update them through reviewed changes. Add optional components only when needed, such as the EBS CSI driver, AWS Load Balancer Controller, or Pod Identity Agent.

**Why it matters:** Core add-ons provide networking, DNS, and node networking proxy functions. Compatibility and planned updates reduce upgrade surprises.

**Use it when:** Before staging workloads and whenever upgrading Kubernetes. Test add-on upgrades in QA before promoting them.

### 4. Add control-plane logs and workload observability

**Current gap:** Control-plane log types are not enabled, and no log retention, metrics, dashboards, or alerts are described in this Terraform.

**Solution:** Enable the logs needed for operations in `aws_eks_cluster`:

```hcl
enabled_cluster_log_types = [
  "api",
  "audit",
  "authenticator",
  "controllerManager",
  "scheduler"
]
```

Create or manage the associated CloudWatch log group with an intentional retention period. Separately collect application and node logs and metrics using CloudWatch Container Insights, Prometheus/Grafana, or your organization’s monitoring platform. Add alerts for unavailable nodes, failed deployments, high resource use, and application errors.

**Why it matters:** Logs help explain failed access, scheduling, and API operations. Metrics and alerts help detect problems before testers or users report them. Retention controls log storage cost and supports audit requirements.

**Use it when:** For every shared environment. Audit and authenticator logs are especially useful when diagnosing access or security events.

### 5. Give workloads their own limited AWS permissions

**Current gap:** There is no IRSA configuration or EKS Pod Identity association. The node role has baseline node permissions, including the VPC CNI policy, but no individual workload roles are defined.

**Solution:** For each workload that calls AWS services, associate its Kubernetes service account with an IAM role using EKS Pod Identity or IRSA. Attach only the permissions that workload needs. For new workloads, consider Pod Identity where the add-on and AWS SDK support it; use IRSA when it better fits existing integrations or organizational requirements. Consider moving VPC CNI permissions from the general node role to a dedicated add-on identity as a hardening step.

**Why it matters:** If every application inherits broad node permissions, a compromised or misconfigured pod may gain access beyond its job. Per-service-account roles support least privilege and make access easier to review.

**Use it when:** Whenever a pod needs access to S3, DynamoDB, Secrets Manager, EBS management, or another AWS API. A workload that only talks to Kubernetes services may not need an AWS role.

### 6. Install the EBS CSI driver only if persistent block storage is needed

**Current gap:** The EBS CSI add-on and its IAM role are not configured.

**Solution:** Install the EKS EBS CSI add-on and give its controller service account a dedicated identity through Pod Identity or IRSA. Attach `AmazonEBSCSIDriverPolicy` to that dedicated role. Define StorageClasses and persistent volume claims as required by the applications. Do not add the EBS policy to the general node role as a shortcut.

**Why it matters:** The CSI driver provisions, attaches, and detaches EBS volumes for Kubernetes persistent volumes. Without it, workloads that request EBS-backed storage cannot get that storage provisioned automatically.

**Use it when:** Databases, queues, or other stateful workloads need durable block storage. It is unnecessary for stateless apps or workloads using another storage system.

### 7. Decide how worker capacity will scale

**Current gap:** The managed node group has min/desired/max size settings, but no component is configured to automatically increase or decrease the node count based on pending pods or utilization.

**Solution:** Keep the fixed node group for predictable small workloads, or install and configure one node autoscaler such as Cluster Autoscaler or Karpenter. Use the Kubernetes Horizontal Pod Autoscaler (HPA) to scale application replicas; HPA generally also needs metrics, commonly from Metrics Server. Node autoscaling and pod autoscaling solve different problems and can be combined.

**Why it matters:** If all nodes are full, new pods remain pending. If the environment is oversized, idle nodes continue to cost money.

**Use it when:** Variable QA/staging test loads, bursty CI workloads, or services with changing traffic. Fixed capacity may be adequate for a small predictable cluster.

### 8. Validate IP capacity and node sizing

**Current gap:** The VPC creates `/24` subnets and the managed node group is configured for 2–4 `t3.medium` nodes. Whether this is sufficient depends on the number of nodes and pods.

**Solution:** Estimate pod IP demand using the selected instance types, Amazon VPC CNI settings, and expected maximum replicas. Ensure private subnet space has room for node and pod addresses, including future growth. If planning a larger cluster, design larger subnets or additional non-overlapping CIDR ranges before deployment; AWS subnet CIDRs are not casually resized after creation.

**Why it matters:** With the Amazon VPC CNI, pods consume VPC addresses. A subnet can run out of IPs even while EC2 capacity remains, preventing new pods from starting.

**Use it when:** Before sizing a shared environment, increasing node counts, or running high-pod-density applications. A small QA cluster may fit the current ranges; verify rather than assume.

### 9. Add the application delivery path

**Current gap:** This Terraform does not create application image repositories, deployment manifests, Helm releases, or a CI/CD pipeline.

**Solution:** Choose a build-and-deploy process. A typical path builds an image, scans it, pushes it to ECR with an immutable version tag, and deploys it using Helm, Kustomize, or reviewed Kubernetes manifests. Configure readiness/liveness probes, CPU and memory requests/limits, replicas, rollout strategy, and rollback. Use an ingress/load-balancer controller plus DNS and TLS if testers need an external application URL.

**Why it matters:** A healthy EKS control plane does not itself build, deploy, expose, or safely update applications.

**Use it when:** Whenever the cluster is expected to host an application. A short-lived manual test can use `kubectl`, but staging should use a repeatable process close to the production release path.

### 10. Set up secrets and workload/network isolation

**Current gap:** No secret-management integration, namespace strategy, Kubernetes RBAC, or NetworkPolicy implementation is shown.

**Solution:** Keep secrets out of Git, Terraform state, and container images. Use AWS Secrets Manager or another approved secrets platform and a supported integration to deliver secrets to workloads. Separate applications or teams by namespace, apply least-privilege RBAC, and use NetworkPolicies if the chosen CNI/policy engine supports and enforces them. Consider Pod Security Standards for workload restrictions.

**Why it matters:** These controls limit accidental exposure and reduce the impact of a compromised application or user account.

**Use it when:** Always avoid committed credentials; namespace and network separation are particularly useful for shared QA/staging clusters and multi-team environments.

### 11. Define backups and recovery

**Current gap:** No persistent-volume backup policy, Kubernetes manifest recovery process, or disaster-recovery procedure is configured here.

**Solution:** Keep cluster and application configuration in version control. Back up persistent data using application-aware backups or AWS Backup/EBS snapshots as appropriate. Document how to recreate the cluster and restore data, then test that procedure. EKS manages the control plane, but that does not back up application data or all cluster configuration for you.

**Why it matters:** A cluster can be recreated from Terraform while databases or other persistent data remain lost unless they have a separate recovery plan.

**Use it when:** Required for stateful workloads and important pre-production data. For disposable QA, define explicitly what can be recreated and what can be discarded.

## Suggested Implementation Order

1. Restrict Kubernetes API access and define admin/CI access.
2. Confirm supported Kubernetes and add-on versions; explicitly manage core add-ons.
3. Enable logs and define monitoring/alerts.
4. Add only required workload identity, storage, load-balancing, and autoscaling components.
5. Verify IP capacity, node sizing, deployment/rollback, secrets, and recovery against the workloads.

Re-run `terraform fmt -check`, `terraform validate`, and `terraform plan` after implementing changes. A plan is not a substitute for checking AWS credentials, permissions, quotas, or service availability, and production-like behavior should be verified in a deployed QA/staging environment.