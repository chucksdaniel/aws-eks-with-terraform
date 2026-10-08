# EKS Terraform Codebase Guide

This guide explains how the current Terraform files fit together, especially how the `environment` value flows through the root configuration into resource names and tags.

## Configuration Flow

The root configuration is the composition layer:

1. `variables.tf` declares settings such as the AWS region, environment, network ranges, Kubernetes version, and node sizing.
2. `main.tf` derives environment-specific names and tags, then passes inputs into the VPC and EKS child modules.
3. `modules/vpc` creates the network and exposes VPC/subnet IDs.
4. `modules/eks` creates IAM roles, the EKS control plane, and its managed worker node group.
5. `outputs.tf` exposes useful IDs, names, and endpoints after deployment.

## Environment Naming Locals

The `locals` block at the top of root `main.tf` calculates values once for reuse. Locals do not create AWS resources; they name or calculate values that other Terraform blocks use.

```hcl
locals {
  vpc_name     = coalesce(var.name, "${var.environment}-eks-vpc")
  cluster_name = coalesce(var.cluster_name, "${var.environment}-eks")
  environment_tags = merge(var.tags, {
    Environment = var.environment
  })
}
```

- `var.environment` is the environment input, for example `dev`, `staging`, `qa`, or `preprod`.
- `var.name` is an optional VPC name override. `coalesce` returns the first value that is not null or empty. If `name` is unset, the VPC name becomes `<environment>-eks-vpc`.
- `var.cluster_name` is an optional EKS cluster name override. If unset, the name becomes `<environment>-eks`.
- `var.tags` contains any additional tags supplied by the operator.
- `merge(var.tags, { Environment = var.environment })` combines those tags with the environment tag. Since the environment map is last, its `Environment` value wins if `var.tags` also contains that key.

Examples:

| `environment` | Default VPC name | Default EKS name | Environment tag |
| --- | --- | --- | --- |
| `dev` | `dev-eks-vpc` | `dev-eks` | `dev` |
| `staging` | `staging-eks-vpc` | `staging-eks` | `staging` |
| `qa` | `qa-eks-vpc` | `qa-eks` | `qa` |

The locals are passed to the VPC and EKS modules:

- VPC receives `local.vpc_name` and `local.environment_tags`.
- EKS receives `local.cluster_name` and `local.environment_tags`.

Child modules cannot automatically see root locals. Passing them as module inputs is what makes the values available there.

## Input Variables

Root `variables.tf` defines configurable inputs and defaults:

- `environment` defaults to `dev`.
- `name` and `cluster_name` default to `null`, so locals derive them from the environment. Setting either explicitly overrides only that generated name.
- `aws_region` and `aws_profile` select the AWS provider configuration.
- `vpc_cidr` and `availability_zones` define the network. A validation requires at least two AZs.
- `kubernetes_version` selects the EKS control-plane version.
- `node_instance_types`, `node_min_size`, `node_desired_size`, and `node_max_size` configure the managed node group.
- `tags` supplies extra resource tags.

Environment-specific values normally come from a local `.tfvars` file or command-line `-var-file`. The repository `.gitignore` excludes `.tfvars` files, so real local values are not committed. Keep secrets out of example files and source control.

## Root Module Wiring

In root `main.tf`:

- `module "vpc"` creates the network. Its outputs are consumed by the EKS module.
- `module "eks"` receives the generated cluster name, Kubernetes version, private subnet IDs, node sizing, and tags.
- `values(module.vpc.private_subnet_ids)` converts the VPC module's map of AZ-to-subnet-ID into a list for EKS.
- `depends_on = [module.vpc]` explicitly orders EKS after the VPC module. The subnet ID references also create implicit dependencies.

## VPC Module

The VPC child module's `local.common_tags` merges user tags with a `Name` tag. The VPC and its resources then add resource-specific names.

- `aws_vpc.this` creates the VPC and enables DNS support and hostnames, which EKS needs for normal cluster networking.
- `aws_internet_gateway.this` attaches an internet gateway to the VPC.
- `aws_subnet.public` creates one public subnet for each configured AZ. `for_each` maps each AZ name to its list index; `each.key` is the AZ and `each.value` is its index. Public subnets map public IPs on launch and carry the `kubernetes.io/role/elb = "1"` load-balancer discovery tag.
- `aws_subnet.private` creates one private subnet per AZ and carries `kubernetes.io/role/internal-elb = "1"` for internal load-balancer discovery.
- `cidrsubnet(var.vpc_cidr, 8, each.value)` divides a `/16` VPC into `/24` public subnets. The `8` is the number of additional prefix bits, not the target prefix itself. `each.value + 10` chooses separate `/24` network numbers for the private subnets.
- `aws_route_table.public` sends the public default route (`0.0.0.0/0`) through the Internet Gateway. Associations attach it to each public subnet.
- `aws_eip.nat` allocates Elastic IP addresses. `aws_nat_gateway.this` creates one NAT Gateway in each public subnet/AZ.
- Each `aws_route_table.private` sends outbound default traffic through the NAT in its AZ. The association connects that route table to the matching private subnet.

The subnet role tags help load-balancer integrations discover eligible subnets. They do not make a subnet public/private by themselves; the route tables determine the network path.

## EKS Module and IAM

In the EKS child module:

- `local.common_tags` combines supplied tags with the cluster name as `Name`.
- `data.aws_iam_policy_document.cluster_assume_role` defines a trust policy allowing the EKS service (`eks.amazonaws.com`) to assume the cluster IAM role.
- `aws_iam_role.cluster` is the control-plane role. `AmazonEKSClusterPolicy` is attached to it.
- `data.aws_iam_policy_document.node_assume_role` allows EC2 (`ec2.amazonaws.com`) to assume the worker role.
- `aws_iam_role.node` is used by managed worker instances. It receives `AmazonEKSWorkerNodePolicy`, `AmazonEKS_CNI_Policy`, and `AmazonEC2ContainerRegistryReadOnly`.
- `aws_eks_cluster.this` creates the EKS control plane in the private subnets. Private and public API endpoint access are both enabled. There is no public CIDR allowlist in the current code, so the public endpoint is reachable from all source IP ranges, subject to EKS authentication. Restrict this for shared environments.
- `aws_eks_node_group.default` creates the managed EC2 worker group in the private subnets. The min/desired/max values bound node count; they do not by themselves install a pod or node autoscaler.
- `depends_on` on policy attachments makes cluster and node-group creation wait for their IAM permissions.

This code does not configure IRSA/OIDC, EKS Pod Identity, EKS add-ons, the EBS CSI driver, access entries/RBAC, control-plane logs, or application deployments. Add those as required by the workloads and operating model. Workload AWS permissions should normally use a dedicated service-account identity rather than broadening the worker-node role.

## Backend and Environment Isolation

`backend.tf` uses an S3 backend without a fixed state key. Terraform backend configuration cannot interpolate normal input variables or root locals. Therefore:

- Resource names can use `var.environment`.
- The environment wrapper reads the checked-out Git branch and selects its matching state key, for example `dev/eks-env/terraform.tfstate` or `staging/eks-env/terraform.tfstate`.
- Always ensure the selected backend key matches the environment variables. A wrong or empty state can make Terraform propose duplicate resources or affect the wrong environment.

The runbook and limitations files in [the knowledge base](README.md) are branch-specific: keep development guidance on `dev` and staging guidance on `staging`.
