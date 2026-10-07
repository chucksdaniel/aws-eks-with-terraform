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

The EKS Terraform creates IAM roles, the EKS control plane, and a managed node group. The control-plane role lets the EKS service manage cluster resources. The node role lets EC2 worker nodes join the cluster, use required networking permissions, and pull images from ECR. The EKS cluster uses the private subnet IDs; the managed node group also launches in those private subnets.

The `kubernetes_version` variable is defined in root `variables.tf`, passed into the EKS module from root `main.tf`, then assigned to `aws_eks_cluster.this.version`. The local `terraform.tfvars` sets it to `1.36`; the variable default is also `1.36`.

The repository `.gitignore` excludes all `*.tfvars` files because they may contain secrets. Consequently, the local `terraform.tfvars` value is not committed or pushed. Keep secrets out of shared files; for team deployments, supply non-secret environment-specific values through the team's approved configuration/CI process.

## Scope Notes

These notes summarize the configuration and explanations discussed; they are not a substitute for checking the exact AWS controller/add-on version documentation or validating a live AWS account. The configuration had passed `terraform validate` during the discussion, but no `terraform apply` or AWS live-state verification was performed.