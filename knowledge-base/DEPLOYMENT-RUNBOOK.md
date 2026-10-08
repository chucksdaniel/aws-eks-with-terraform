# Development EKS Deployment Runbook

This runbook applies only to the **development** environment. Its default cluster name is `dev-eks`, its VPC name is `dev-eks-vpc`, and its Terraform state key is `dev/eks-env/terraform.tfstate`.

## 1. Prepare the development settings

Create the ignored local file `environments/dev.tfvars` from `environments/dev.tfvars.example` if it does not exist. Review it and confirm it contains:

```hcl
environment = "dev"
```

Keep credentials and secrets out of this file. It is excluded from Git by the repository's `*.tfvars` ignore rule.

## 2. Confirm the AWS account

The configured profile is `chuks` in `us-east-1`. Confirm it points to the intended development account:

```sh
aws sts get-caller-identity --profile chuks
```

Do not continue if the account is unexpected. Confirm the configured S3 state bucket exists and the profile can read/write state and use the state lock file.

## 3. Initialize development state and inspect the plan

From the repository root, select development explicitly:

```sh
bash scripts/terraform-env.sh plan
```

The script checks that the local settings say `environment = "dev"`, initializes the S3 backend at `dev/eks-env/terraform.tfstate`, validates Terraform, and creates a plan.

Review the entire plan before applying. Confirm that resources are named for development, the account and region are correct, and there are no unexpected replacements or deletions. Stop if the state is empty or the plan appears to duplicate existing development resources.

## 4. Apply development infrastructure

After reviewing the plan:

```sh
bash scripts/terraform-env.sh apply
```

Terraform will show a plan and ask for approval. Review it again. The VPC, NAT Gateways, EKS cluster, and EC2 nodes create AWS charges.

## 5. Verify access and nodes

The public EKS API endpoint is enabled in the current module. It is not restricted by source CIDRs, so for a shared development environment, restrict access to a trusted VPN or administrator IPs before relying on the cluster.

Configure `kubectl` using the name from this development state:

```sh
CLUSTER_NAME="$(terraform output -raw eks_cluster_name)"
aws eks update-kubeconfig \
  --region us-east-1 \
  --name "$CLUSTER_NAME" \
  --profile chuks
kubectl get nodes
kubectl get pods --all-namespaces
```

Confirm both expected nodes become `Ready`. Then use the team's approved Kubernetes manifests or Helm chart to deploy a small development workload and check that it starts and can reach the services it needs.

## 6. Save development Terraform outputs

To refresh the output snapshot for the currently selected development state:

```sh
bash scripts/terraform-env.sh output
```

This writes the Terraform outputs to `knowledge-base/output.md`, replacing its previous contents. The file is development-specific on this branch. Review it before committing; do not include credentials or secrets in Terraform outputs.

## 7. Remove development infrastructure only when intended

First review a destroy plan:

```sh
bash scripts/terraform-env.sh plan -destroy
```

Only if every deletion is expected, run:

```sh
bash scripts/terraform-env.sh destroy
```

The script selects the development state key for both commands. Never use destroy to change environments.
