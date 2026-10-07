# EKS Environment Runbook

Use this runbook whenever planning, applying, or changing the EKS Terraform for an environment. Resource names are derived from the `environment` input in `main.tf`:

- `environment = "dev"` produces cluster `dev-eks` and VPC `dev-eks-vpc`.
- `environment = "staging"` produces cluster `staging-eks` and VPC `staging-eks-vpc`.
- The `Environment` tag is also set from this input.
- Optional `cluster_name` and `name` variables can override the generated names.

Changing a name or environment does **not** select a separate Terraform state automatically. Each environment must use its own state key.

## Current Configuration Warning

At the time this runbook was written:

- `terraform.tfvars` sets `environment = "dev"`.
- `staging.tfvars.example` sets `environment = "staging"`.
- `backend.tf` defaults to the S3 key `staging/eks-env/terraform.tfstate`.

Therefore the auto-loaded default variables say **dev** while the default backend key says **staging**. Do not run `terraform apply` until you explicitly select matching environment variables and backend state. Terraform's `.tfvars` files are git-ignored; keep real environment files local and do not put secrets in committed examples.

## One-Time Preparation

1. Confirm the AWS profile and account. The current provider and backend configuration use profile `chuks` by default:

   ```sh
   aws sts get-caller-identity --profile chuks
   ```

   Confirm the returned account is the account where the chosen environment belongs. If you use a different profile, update the provider and backend configuration consistently.

2. Make local environment variable files. The example is a template, not a secret store:

   ```sh
   cp terraform.tfvars dev.tfvars
   cp staging.tfvars.example staging.tfvars
   ```

   Review each file. Confirm `dev.tfvars` contains `environment = "dev"`, and `staging.tfvars` contains `environment = "staging"` plus the intended version and node sizes. These files are ignored by Git.

3. Confirm the intended S3 bucket exists and that the AWS identity can read/write the state and use the lock file. The backend enables S3 encryption and lock files.

## Select and Plan an Environment

Run from the repository root. Backend configuration and variable files must refer to the same environment.

### Development

```sh
terraform init -reconfigure \
  -backend-config="key=dev/eks-env/terraform.tfstate"
terraform fmt -check
terraform validate
terraform plan -var-file="dev.tfvars"
```

### Staging

```sh
terraform init -reconfigure \
  -backend-config="key=staging/eks-env/terraform.tfstate"
terraform fmt -check
terraform validate
terraform plan -var-file="staging.tfvars"
```

The `-backend-config` key overrides the key in `backend.tf` for that initialization. `-reconfigure` selects the requested state location; it does not copy state. If you are intentionally moving an existing environment from one state key to another, stop and plan a state migration instead. Do not use `-migrate-state` as a routine environment switch.

Before applying a plan, check:

- The selected variable file's `environment` matches the intended environment.
- The backend key is the correct unique key for that environment.
- The AWS account/profile is correct.
- The plan changes only the intended environment's resources. A new empty state can make Terraform propose creating a second copy of resources.
- Any destructive, replacement, or unexpected changes are understood.

## Apply and Verify

Only after reviewing the plan:

```sh
terraform apply -var-file="staging.tfvars"
```

For development, substitute `dev.tfvars`. Do not apply while the selected backend and variables refer to different environments. After apply, verify the EKS cluster, managed node group, VPC subnets/routes, and AWS console events. Then configure/verify EKS administrator access and deploy a small test workload before treating the environment as ready.

## Later Changes and Cleanup

- To work on another environment, run `terraform init -reconfigure` with that environment's state key and use its matching `-var-file` on every plan/apply.
- Re-run `terraform plan` and review it before each apply. Resource changes, including environment/name changes, may replace resources or create a separate cluster.
- For upgrades, check EKS Kubernetes and add-on compatibility, plan the control-plane and node-group upgrade, and test in QA before staging.
- To destroy an environment, first select its exact backend key and variable file, then inspect `terraform plan -destroy -var-file="staging.tfvars"`. Apply destroy only after confirming the selected state contains only that environment. Never destroy as a way to switch environments.
- Keep Terraform state private; it can contain sensitive infrastructure data. Do not commit state, plan files, credentials, or real `.tfvars` files.

## Guidance for Future Sessions

Before editing or running Terraform in a later work session:

1. Read this runbook and `EKS-READINESS-SOLUTIONS.md`.
2. Check `git status`, the current branch, `backend.tf`, and the selected environment variable file.
3. Verify the environment name, AWS account/profile, and backend key all match.
4. Inspect current state and a Terraform plan before making infrastructure changes.
5. Do not apply or migrate state unless explicitly requested and the plan has been reviewed.
