# EKS Deployment Runbook

This runbook deploys the Terraform-managed VPC, EKS control plane, and managed node group. It assumes the AWS profile, S3 backend bucket, and required permissions are already configured. It does not install application workloads or add optional components such as the EBS CSI driver.

## Before You Start

- Run commands from the `AWS-EKS-TF` repository root.
- Confirm the AWS account and region are the intended target. The current defaults use profile `chuks` and region `us-east-1`.
- Confirm the S3 state bucket in `backend.tf` exists and that this identity can read/write the state and use the lock file.
- Review `backend.tf`: its checked-in default key is `staging/eks-env/terraform.tfstate`, while the checked-in local `terraform.tfvars` currently sets `environment = "dev"`. Always select a matching backend key and variable file. Do not apply with this mismatch.
- The EKS public API endpoint is currently enabled without a public CIDR allowlist. Restrict it to trusted administrator/VPN addresses before using a shared staging or pre-production cluster.
- Ensure the selected Kubernetes version is currently offered in the target region, and review NAT Gateway, EKS, and EC2 costs.

Check the AWS identity:

```sh
aws sts get-caller-identity --profile chuks
```

If you use a different profile, ensure both the AWS provider and backend use it consistently.

## Prepare Environment Variables

The environment input generates names by default:

- `dev` produces cluster `dev-eks` and VPC `dev-eks-vpc`.
- `staging` produces cluster `staging-eks` and VPC `staging-eks-vpc`.

`cluster_name` and `name` can override these generated names. Do not override them unless intentional.

The repository ignores `.tfvars` files. Keep real environment-specific values local and never add credentials or secrets to a committed example.

### Development

The local `terraform.tfvars` is currently the dev input file. Review it and confirm it says:

```hcl
environment = "dev"
```

### Staging

Create a local staging variable file from the dev settings, then change the environment and any staging-specific sizes/settings:

```sh
cp terraform.tfvars staging.tfvars
```

Edit `staging.tfvars` and set:

```hcl
environment = "staging"
```

Keep only the non-secret settings needed for this environment. Terraform automatically loads `terraform.tfvars`; specifying `-var-file="staging.tfvars"` gives the staging file explicit precedence for the values it contains.

## Initialize, Validate, and Plan

Use a different state key for each environment. `backend.tf` cannot interpolate `var.environment`, so pass the key to `terraform init`. `-reconfigure` selects a backend; it does not copy or migrate state.

### Development

```sh
terraform init -reconfigure \
  -backend-config="key=dev/eks-env/terraform.tfstate"
terraform fmt -check main.tf variables.tf outputs.tf providers.tf modules/vpc/variables.tf modules/vpc/outputs.tf modules/eks/main.tf modules/eks/variables.tf modules/eks/outputs.tf
terraform validate
terraform plan -var-file="terraform.tfvars"
```

### Staging

```sh
terraform init -reconfigure \
  -backend-config="key=staging/eks-env/terraform.tfstate"
terraform fmt -check main.tf variables.tf outputs.tf providers.tf modules/vpc/variables.tf modules/vpc/outputs.tf modules/eks/main.tf modules/eks/variables.tf modules/eks/outputs.tf
terraform validate
terraform plan -var-file="staging.tfvars"
```

Before proceeding, inspect the plan and confirm all of the following:

1. The input file's `environment` matches the intended environment.
2. The S3 state key is unique to that same environment.
3. The AWS account/profile and region are correct.
4. The plan changes only the intended resources. A new or wrong empty state may propose duplicate infrastructure.
5. Replacements, deletions, and unexpected resource changes are understood.
6. The public API endpoint exposure is acceptable and any needed access restriction has been configured.

If Terraform proposes managing resources that already exist but are absent from the selected state, stop and investigate. Do not apply simply to make the plan succeed, and do not use `-migrate-state` for routine environment switching.

## Apply

Only after reviewing the plan, apply the matching environment:

```sh
terraform apply -var-file="terraform.tfvars"
```

For staging, use:

```sh
terraform apply -var-file="staging.tfvars"
```

Terraform displays a plan and asks for confirmation. Review it again before approving. Applying creates billable AWS resources, including NAT Gateways, EKS, and EC2 worker nodes.

## Verify the Cluster

Use Terraform outputs and AWS CLI to configure `kubectl` for the cluster in the currently selected state:

```sh
CLUSTER_NAME="$(terraform output -raw eks_cluster_name)"
aws eks update-kubeconfig \
  --region us-east-1 \
  --name "$CLUSTER_NAME" \
  --profile chuks
kubectl get nodes
kubectl get pods --all-namespaces
```

Confirm the expected worker nodes become `Ready`. Check EKS events and node-group status in the AWS console if creation or node registration fails. Then deploy a small application using the team's approved manifests/Helm release and verify its readiness, logs, network access, and rollback procedure.

This Terraform currently does not explicitly create EKS add-ons, access entries/RBAC, workload IAM identities, EBS CSI storage, observability, or an application pipeline. Configure the pieces required by your workload and operating model before calling the environment production-like.

## Switching Environments Safely

To switch environments, initialize the other environment's state key and always use its matching variable file for every plan, apply, or destroy. For example, switching from staging to dev:

```sh
terraform init -reconfigure \
  -backend-config="key=dev/eks-env/terraform.tfstate"
terraform plan -var-file="terraform.tfvars"
```

Do not assume that changing `environment` changes the backend state. Backend state is selected independently. Before any apply, verify account, state key, and environment together.

## Destroying an Environment

Destroy only when intentionally removing an environment. Select its exact backend key first, then inspect the destroy plan with the matching variable file:

```sh
terraform plan -destroy -var-file="staging.tfvars"
```

Read every planned deletion and confirm the selected state belongs only to staging before running `terraform destroy -var-file="staging.tfvars"`. Use the dev variable file and dev backend key only when destroying dev. Never destroy as a way to switch environments.

## Future Sessions

At the start of a later work session:

1. Read this runbook and `CODEBASE-GUIDE.md`.
2. Check the branch and `git status` before editing.
3. Read the current `backend.tf`, selected `.tfvars`, and relevant Terraform files; do not assume values from an earlier session are still current.
4. Verify AWS account, environment, and backend key all match before planning.
5. Run `terraform validate` and inspect `terraform plan` before making infrastructure changes.
6. Do not apply, migrate, or destroy infrastructure without explicit approval and a reviewed plan.
