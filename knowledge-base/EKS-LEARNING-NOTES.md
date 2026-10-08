# EKS Learning Notes

These notes collect the explanations from our EKS/VPC discussion. The recent cluster-readiness and IAM discussion is summarized first, followed by the earlier VPC and Terraform concepts.

## Recent Discussion: Identity, Readiness, and Current Setup

### Which workload identity method is configured?

The current Terraform configures neither IRSA nor EKS Pod Identity for workloads. It creates two IAM roles:

- The EKS cluster role, trusted by `eks.amazonaws.com`, gives the EKS control plane AWS permissions.
- The worker-node role, trusted by `ec2.amazonaws.com`, gives EC2 worker machines their baseline permissions.

The node role currently has `AmazonEKSWorkerNodePolicy`, `AmazonEKS_CNI_Policy`, and `AmazonEC2ContainerRegistryReadOnly`. These are baseline node permissions, not individual permissions for each application.

An EKS cluster publishes an OIDC issuer URL, but this Terraform does not register that issuer as an IAM OIDC provider or configure an IRSA role. It also does not create EKS Pod Identity associations.

An IAM role is like a permission badge. The node role gives the machine a badge. IRSA or Pod Identity can give a particular Kubernetes service account, and therefore its pods, a separate badge with narrower permissions.

For a new setup, EKS Pod Identity is often the simpler option when the workload or add-on supports it. IRSA remains a valid, widely used alternative. Both can provide permissions to a service account without broadly granting application permissions to every worker node.

### EBS permissions and OIDC

OIDC is not an EBS permission. The EBS CSI driver needs an IAM policy that allows it to manage EBS volumes, commonly `AmazonEBSCSIDriverPolicy`. OIDC/IRSA is one way for the driver to prove its identity to AWS and receive that policy. EKS Pod Identity is another way and does not require configuring an IAM OIDC provider.

The current Terraform does not install the EBS CSI add-on or assign it a role. That is only needed if workloads require persistent EBS-backed storage.

### OIDC certificate retrieval

The current code does not retrieve an OIDC certificate thumbprint. For an IRSA setup, Terraform can read the EKS cluster's OIDC issuer URL, connect to that HTTPS endpoint, and retrieve its certificate chain/fingerprint through a TLS certificate data source. The fingerprint is used when registering the IAM OIDC provider. This is the issuer endpoint's HTTPS certificate, not the Kubernetes API certificate. Pod Identity does not need this OIDC setup.

### What a staging/QA/pre-production cluster needs

A cluster is ready for a particular environment when it can run the intended workloads securely, reach required services, and be monitored and recovered. A useful checklist is:

- Supported Kubernetes version and compatible EKS add-on versions.
- Private worker subnets across at least two Availability Zones, with working egress to required AWS services and registries through NAT or VPC endpoints.
- Restricted Kubernetes API access, preferably through private access/VPN or a public endpoint limited to trusted IP addresses.
- Adequate VPC IP capacity, since pods use VPC addresses with the Amazon VPC CNI.
- Deliberate administrator and CI/CD access, using EKS access entries and Kubernetes RBAC.
- Least-privilege workload IAM roles using Pod Identity or IRSA where apps need AWS permissions.
- EKS core add-ons maintained at compatible versions; EBS CSI, load-balancer controller, metrics, and autoscaling components added when needed.
- Image storage/scanning, repeatable deployments, resource requests and limits, health probes, and rollout/rollback procedures.
- Control-plane and workload logs, metrics, alerts, patching, backups, and recovery procedures appropriate to the environment.

QA can be smaller and shared or short-lived. Staging should resemble production enough to reveal deployment issues. Pre-production should be as production-like as practical, including access controls, networking, monitoring, and release procedures.

### Does the current configuration meet that checklist?

It is a solid cluster foundation and Terraform validation passed, but it is not yet a complete shared staging or pre-production setup.

Already configured:

- VPC DNS support and hostnames.
- Public/private subnets in two Availability Zones.
- One NAT Gateway per AZ, with private subnet routes using the NAT in the same AZ.
- EKS control plane and managed node group in private subnets.
- Baseline cluster and worker IAM roles/policies.
- Public and private subnet role tags for load-balancer discovery.
- Kubernetes version `1.36`; the selected version was in EKS standard support when reviewed.

Needs attention or an environment-specific decision:

- The Kubernetes API public endpoint is enabled without a public source-IP allowlist. Restrict it to trusted addresses or use private connectivity.
- EKS access entries/RBAC for administrators and deployment automation are not configured here.
- EKS add-on versions, control-plane logging, monitoring/alerts, backups, and node autoscaling are not explicitly configured here.
- No workload identity association is configured. Use Pod Identity or IRSA for applications that need AWS permissions.
- The EBS CSI driver is not installed; add it only if persistent EBS storage is needed.
- Confirm subnet IP capacity and the fixed worker-node capacity are appropriate for the expected pod count and workload.

This is a Terraform code review, not a live AWS deployment test. `terraform validate` confirms configuration structure but does not verify AWS credentials, account permissions, service quotas, or resource availability.

## VPC and Subnet Concepts

### VPC readiness for EKS

The VPC module enables DNS, creates public and private subnets in two AZs, attaches an Internet Gateway to public routing, and creates a NAT Gateway for each AZ. EKS and its managed nodes use the private subnet IDs directly. This is a suitable basic network layout for EKS.

The public/private role tags help AWS load-balancer integrations discover suitable subnets:

- `kubernetes.io/role/elb = "1"` marks a subnet as eligible for internet-facing load balancers.
- `kubernetes.io/role/internal-elb = "1"` marks a subnet as eligible for internal load balancers.

These tags are labels; they do not make a subnet public or create a load balancer. Routes determine whether a subnet has internet access. The current module already applies the role tags to public and private subnets respectively.

A cluster ownership tag such as `kubernetes.io/cluster/<cluster-name> = "shared"` associates a subnet/resource with a cluster for integrations that use that discovery convention. It is different from the role tags. Whether it is needed depends on the integration and its version; check that component's subnet-discovery documentation. It is not required just to create this EKS cluster because subnet IDs are passed explicitly.

### Understanding the highlighted Terraform subnet code

The public subnet resource creates a subnet for each availability zone. `for_each` repeats the resource using a map made from the AZ list. `each.key` is the current AZ name; `each.value` is its zero-based number (0, 1, ...). `vpc_id` places the subnet inside the VPC, and `map_public_ip_on_launch = true` makes instances launched there receive public IPv4 addresses by default.

`tags` add labels. The `Name` is built from the VPC name and AZ; `Tier = "public"` is descriptive only. The public route table pointing to the Internet Gateway is what provides the internet route.

### CIDR, `/24`, `/18`, and `cidrsubnet`

An IPv4 address has 32 bits. A CIDR prefix such as `/18` says that 18 bits identify the network, leaving `32 - 18 = 14` bits for addresses inside it. Therefore a `/18` contains `2^14 = 16,384` total addresses. AWS reserves 5 addresses in each subnet, leaving 16,379 usable addresses. A `/24` contains 256 total and 251 usable AWS addresses.

Terraform's `cidrsubnet(prefix, newbits, netnum)` divides a larger range into smaller ranges:

- `prefix` is the VPC CIDR, for example `10.0.0.0/16`.
- `newbits` is how many bits Terraform adds to the prefix length.
- `netnum` chooses which resulting subnet range to use.

With a `/16` VPC, `cidrsubnet(var.vpc_cidr, 8, 0)` creates `10.0.0.0/24`; using net number 1 creates `10.0.1.0/24`. The `8` is not the desired CIDR itself; `/16 + 8 bits = /24`.

To create `/18` subnets inside a `/16`, use `newbits = 2`, because `/16 + 2 = /18`. The four available `/18` ranges are:

| Net number | Range |
| --- | --- |
| 0 | `10.0.0.0/18` |
| 1 | `10.0.64.0/18` |
| 2 | `10.0.128.0/18` |
| 3 | `10.0.192.0/18` |

A `/16` can fit four `/18` subnets. The current private subnet expression adds 10 to its subnet number, which fits the `/24` layout but would not fit if changed directly to `/18`. With two AZs and public/private pairs at `/18`, choose distinct net numbers 0 through 3, for example public 0 and 1, private 2 and 3.

Other examples within a `/16`:

- `/18`: 4 subnets, 16,384 addresses each.
- `/20`: 16 subnets, 4,096 addresses each.
- `/24`: 256 subnets, 256 addresses each.

### Why one NAT Gateway versus one per AZ?

A NAT Gateway is zonal. If private subnets in several AZs all route through one NAT in AZ-A, traffic from other AZs crosses an AZ boundary to reach it. That can add cross-AZ data-transfer charges. If the NAT's AZ has an outage, private subnets in other AZs that depend on it can also lose outbound connectivity.

With one NAT per AZ, each private subnet can route through the NAT in its own AZ. This improves availability and avoids cross-AZ NAT paths, at the cost of paying the hourly charge for each NAT Gateway. The current Terraform creates one NAT per public subnet/AZ and maps each private route table to the NAT with the same AZ key.

NAT is for outbound connections from private resources; it does not make those resources directly reachable from the internet. For low-traffic development, a single NAT can reduce fixed cost, but has the availability and cross-AZ tradeoffs above. VPC endpoints can avoid NAT for supported AWS services.

## EKS Terraform and Version Settings

### Minimum, Desired, and Maximum Node Counts

The managed node group's scaling settings follow this rule:

```text
minimum <= desired <= maximum
```

Think of the values as a floor, target, and ceiling:

- `node_min_size` is the smallest number of worker nodes the group should keep.
- `node_desired_size` is the number of worker nodes the group should try to run now.
- `node_max_size` is the largest number of worker nodes the group is allowed to reach.

For example, `minimum = 1`, `desired = 2`, and `maximum = 4` is valid. It asks for two workers, permits the count to go down to one, and permits it to grow as high as four. It does not guarantee enough capacity or availability for every workload. With only one worker available, a node failure or maintenance event can leave the cluster without enough room for its pods. A small development cluster may accept that tradeoff; shared staging or production-like environments often keep at least two workers for resilience.

The current development values are `minimum = 2`, `desired = 2`, and `maximum = 4`. These values are configured in `environments/dev.tfvars`.

In this codebase, no Cluster Autoscaler or Karpenter is configured. Therefore the desired count stays at the configured value unless an operator changes it or another scaling component is installed. Minimum and maximum are bounds; they do not independently make the node group scale up or down. Kubernetes pod autoscaling is separate: it changes the number of application pods, while node autoscaling changes the number of worker machines.

The EKS Terraform creates IAM roles, the EKS control plane, and a managed node group. The control-plane role lets the EKS service manage cluster resources. The node role lets EC2 worker nodes join the cluster, use required networking permissions, and pull images from ECR. The EKS cluster uses the private subnet IDs; the managed node group also launches in those private subnets.

The `kubernetes_version` variable is defined in root `variables.tf`, passed into the EKS module from root `main.tf`, then assigned to `aws_eks_cluster.this.version`. The local `terraform.tfvars` sets it to `1.36`; the variable default is also `1.36`.

The repository `.gitignore` excludes all `*.tfvars` files because they may contain secrets. Consequently, the local `terraform.tfvars` value is not committed or pushed. Keep secrets out of shared files; for team deployments, supply non-secret environment-specific values through the team's approved configuration/CI process.

## What a Launch Template Does in EKS Provisioning

An AWS launch template is an EC2 launch configuration template that can define the settings used when a new EC2 instance is created. For an EKS managed node group, it can define or influence the instance image, instance type, networking, bootstrap user data, security groups, block devices, and instance tags.

The launch template is not a Kubernetes resource and it is not the EKS node group itself. It is the AWS object that describes how the managed node group launches its EC2 worker machines. The EKS node group remains the Kubernetes-facing resource that controls the desired, minimum, and maximum worker count, node role, subnets, and update behavior.

A launch template is needed when the managed node group must use custom EC2 launch behavior. Common reasons include:

- Adding an EC2 `Name` tag or other instance-level tags.
- Applying a custom AMI or launch configuration.
- Adding custom user data or bootstrap configuration.
- Controlling instance type, security groups, networking, or block-device settings.
- Reusing the same launch configuration across multiple node groups or environments.

It was not present in the initial provisioning because EKS managed node groups can use their default launch behavior. The original configuration had enough information to create the EKS cluster, worker role, subnets, instance types, and scaling settings without a custom launch template. EKS therefore launched the worker EC2 instances using its managed defaults. This was sufficient for basic development provisioning, but it did not provide a durable mechanism to set the EC2 `Name` tag on every worker instance.

The current module creates `aws_launch_template.nodes` with an instance tag specification. The `resource_type = "instance"` block applies the tags to EC2 instances rather than to the launch template or node group. The `Name` value is set to `${var.cluster_name}-worker`, while `local.common_tags` also supplies shared tags such as `Environment`.

The `aws_eks_node_group.default` resource then references that launch template through its `launch_template` block. EKS uses the template when it creates a worker instance, and future replacement or autoscaled instances receive the template's instance specifications. This makes the Name tag repeatable instead of relying on a one-time manual tag.

Adding a launch template is a configuration change, not a Kubernetes cluster bootstrap step. The EKS service still performs the Kubernetes bootstrap, joins the node to the cluster, and applies the node role and subnet configuration. The launch template supplies the EC2 launch details; the node group controls how many workers and how they are managed.

Changing the launch template can cause replacement or update work because the EKS node group may need to roll out new instances. Review `terraform plan` before applying, especially when the template is newly introduced or its version changes. Do not assume that tags on `aws_eks_node_group.default` automatically become EC2 instance tags.

## Worker Node Operating System and Instance Type

The live worker instance was inspected in the current `dev` environment. It is running on:

- **Instance type:** `t3.medium`
- **Operating system:** Amazon Linux 2023
- **Kubernetes node AMI:** `amazon-eks-node-al2023-x86_64-standard-1.36-v20260930`
- **Kubernetes version:** `1.36.4`
- **Container runtime:** `containerd` 2.x

This is an EKS-optimized Amazon Linux 2023 node image, not Red Hat or Ubuntu. EKS supplies and manages the optimized AMI. The AMI version and Kubernetes version are selected by the EKS service and can change over time; do not manually replace the operating system or AMI on an existing worker node.

### Best-practice operating system

For a managed EKS node group, the recommended practice is to use an EKS-optimized operating-system image that is supported for the selected Kubernetes version. In this configuration, that means the EKS-optimized Amazon Linux 2023 image currently associated with Kubernetes 1.36.4. This is the best default because EKS provides the required bootstrap process, security updates, compatibility testing, and node-image lifecycle management.

Red Hat or Ubuntu can be used with a custom managed node group or custom launch template, but that requires additional work: selecting a compatible AMI, validating the EKS bootstrap process, installing and maintaining the container runtime, and testing node upgrades and security patches. It is not the simplest or lowest-risk choice for a new managed node group.

Use the EKS-supported image whenever possible. For production, also verify that the selected Kubernetes and EKS node-image versions are supported and that the operating-system patch level is approved by the organization. Do not mix a custom OS with the default EKS managed-node behavior without validating the full bootstrap and upgrade path.

### Production migration recommendation

For a production migration, use the same EKS-supported operating-system image as the current development node group unless a specific application dependency requires another operating system. Amazon Linux is AWS-native and is the lowest-risk default because it integrates with EKS, AWS IAM, ECR, EC2, and the EKS node bootstrap process.

Recommended production migration sequence:

1. Run the application on an EKS-managed node group using the EKS-optimized Amazon Linux image.
2. Validate application compatibility, package installation, CPU, memory, storage, networking, and security policies in a test or staging environment.
3. Use a new node group or a controlled rollout so the existing environment remains available for rollback.
4. Verify that the production Kubernetes and node-image versions are supported and approved.
5. Migrate workloads gradually, keeping the previous environment available until validation is complete.
6. Review the production node group, update policy, logging, monitoring, and image patching before final cutover.

Amazon Linux is the preferred choice when the workload can run on it. Ubuntu is a reasonable option when an application depends on its package ecosystem or a specific service, while Red Hat is useful for organizations that need an established enterprise operating system and support model. In every case, use a supported EKS-compatible AMI and validate the full upgrade and replacement path.

The current configuration declares `node_instance_types = ["t3.medium"]`, which appears in `environments/dev.tfvars` and the root variable default. The exact `t3.medium` instance type is therefore the one selected for the managed node group. The AMI is determined by the EKS node image associated with the cluster Kubernetes version, not by the Terraform `instance_types` value.

### Choosing an instance type for workloads

`t3.medium` is a reasonable starting point for development and small workloads because it provides a balanced combination of vCPU, memory, and cost. It is suitable for many lightweight APIs, test applications, and small services, but it may be too small for memory-heavy workloads, large databases, or workloads with high CPU use.

Choose an instance type based on the workload's measured resource requirements rather than choosing an operating system as the primary factor:

- **CPU-heavy workloads:** larger compute-oriented instances such as `m5.large`, `m5.xlarge`, or a family optimized for compute.
- **Memory-heavy workloads:** instances with the required memory-to-vCPU ratio, such as `r5.large` or `r5.xlarge`, depending on the workload.
- **General development or small services:** `t3.medium` is a practical default.
- **Production-like or high availability:** use at least two nodes across separate Availability Zones and choose a size based on capacity testing and load testing.
- **GPU or specialized workloads:** use a GPU-enabled instance family and ensure the EKS AMI and driver stack support it.

A larger instance can reduce the number of nodes needed, but it is not automatically better. It may cost more and can fail when a pod requests a large amount of memory, CPU, or storage. Measure actual pod requests, node utilization, and scheduling behavior before changing the instance type.

For production and staging, prefer a stable instance family with an EKS-optimized AMI, an approved security baseline, and explicit node sizing. Treat the operating system as part of the EKS-managed node image rather than as a choice made in the Terraform configuration.

## Worker EC2 Name Tags and Saved Terraform Outputs

The managed node group has a `tags` block with a `Name` value, but that tag does not necessarily become the EC2 `Name` tag on each worker instance. The node group is an EKS resource; its tags identify the node group and may be applied to related Auto Scaling resources. EC2 instance tags must be specified as launch-template instance tag specifications.

For future managed node-group creation, define a launch template with instance tag specifications and attach it to the node group:

```hcl
resource "aws_launch_template" "nodes" {
	name_prefix = "${var.cluster_name}-nodes-"

	tag_specifications {
		resource_type = "instance"
		tags = merge(local.common_tags, {
			Name = "${var.cluster_name}-worker"
		})
	}
}

resource "aws_eks_node_group" "default" {
	# Keep the existing node-group arguments.

	launch_template {
		id      = aws_launch_template.nodes.id
		version = tostring(aws_launch_template.nodes.latest_version)
	}
}
```

The same `Name` value will appear on each instance; use other tags such as cluster and environment to distinguish them. If a managed node group was created without a custom launch template, adding one may require replacing the node group. Review `terraform plan` for replacement and schedule the change to avoid interrupting workloads. Do not manually add instance tags as the lasting fix, because replacement or autoscaled instances will not inherit those manual changes.

The current output snapshot is kept in `knowledge-base/output.md`. Refresh it for the active Git branch after provisioning with:

```sh
bash scripts/terraform-env.sh output
```

That command selects the branch's backend state, runs `terraform output`, and overwrites the snapshot. The snapshot is environment-specific; only update or commit it from the branch/environment it represents. Terraform outputs should not contain secrets.

## Scope Notes

These notes summarize the configuration and explanations discussed; they are not a substitute for checking the exact AWS controller/add-on version documentation or validating a live AWS account. The configuration had passed `terraform validate` during the discussion, but no `terraform apply` or AWS live-state verification was performed.