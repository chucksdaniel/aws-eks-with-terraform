# EKS Terraform Collaboration and Access Onboarding

This guide onboards a second contributor to this repository. It covers Git collaboration, Terraform access to the shared AWS account and remote state, and Kubernetes access to the EKS cluster. These are separate permissions: AWS administrator access does not automatically grant access to Kubernetes.

## 1. Understand the current access model

The current Terraform configuration creates the VPC, EKS control plane, and managed node group. The EKS module does not currently declare EKS access entries, an authentication mode, or Kubernetes RBAC for human users. Do not assume that an AWS administrator identity can run `kubectl` successfully until it is explicitly mapped to the cluster.

The current repository also has AWS profile `chuks` configured in `backend.tf` and as the default `aws_profile` in `variables.tf` and the environment examples. The profile name is local to each workstation; it is not an AWS identity and credentials must not be copied from another contributor. The shared backend is the S3 bucket `opumaks-terraform-state`, with separate keys selected by `scripts/terraform-env.sh` for `dev` and `staging`, and S3 lockfile locking enabled.

Before changing access or infrastructure, confirm the actual state and account for the environment being worked on. The currently checked-out branch and corresponding files may differ by environment.

## 2. Have the repository owner onboard the contributor

The repository/cluster owner should:

1. Invite the contributor to the Git host and grant the minimum repository permission needed to create branches and pull requests.
2. Provide the contributor with their own access to the intended AWS account. Prefer AWS IAM Identity Center (SSO); do not send access keys or reuse another person's profile. For SSO, an AWS administrator should:
    - Open **IAM Identity Center** in the AWS Console and ensure it is enabled and connected to the organization's identity source.
    - Add/invite the contributor in the identity source (or sync their account from the organization's directory), then add them to the appropriate access group.
    - In **AWS accounts**, select the target account and assign that group or user a permission set. Grant only the permissions required for the approved work; Terraform contributors also need permissions to the relevant infrastructure and, if they will plan using shared state, the appropriate S3 state/lockfile and KMS access. AWS account permissions do not grant Kubernetes access by themselves.
    - Give the contributor the organization's AWS access portal start URL, the IAM Identity Center region, and the target AWS account/role details. Do not send passwords or temporary credentials.

    The contributor configures and verifies their own named CLI profile:

    ```sh
    aws configure sso --profile collaborator
    aws sso login --profile collaborator
    aws sts get-caller-identity --profile collaborator
    ```

    During configuration, they enter the provided start URL and SSO region, select the assigned account and role, and choose a local profile name such as `collaborator`. Continue only when `get-caller-identity` shows the intended account and assigned role. If the contributor already has their own AWS credentials, first run `aws sts get-caller-identity` with those credentials and confirm the returned account and principal with the owner; existing AWS administrator permissions still do not provide EKS Kubernetes access until the principal is mapped and granted RBAC below. An assumable IAM role is an alternative only when the account owner has configured and approved its trust relationship and permissions.
3. Decide which environment the contributor may work on. Start with development; staging and production access should require explicit approval.
4. Assign a role from the permission profiles below, customized to the account, environment, and actual tasks. These are permission profiles to implement as reviewed IAM Identity Center permission sets/IAM roles and Kubernetes RBAC, not AWS managed-policy names to attach without review.
5. If the contributor will use Terraform against the shared backend, grant the appropriate S3 permissions to the relevant state object and the bucket permissions required for the S3 lockfile. Apply account-level encryption/KMS permissions if the bucket uses a customer-managed key. Do not give access to unrelated state keys or environments.
6. Add the contributor's IAM role ARN to the EKS cluster using the approved access-entry or legacy `aws-auth` process below, then give the contributor the cluster name, AWS region, environment, required client tools, and permitted Kubernetes scope.
7. Keep at least one existing, tested administrator identity available while changing cluster access. Validate the new identity before removing any existing access.

### Suggested enterprise role and permission profiles

AWS IAM permissions and Kubernetes RBAC are separate layers. AWS permissions control AWS APIs and Terraform/state access; an EKS access entry (or legacy `aws-auth` mapping) authenticates the principal to Kubernetes, and Kubernetes RBAC or an EKS access policy controls `kubectl`. Grant access only to the environments and resources each person needs. In particular, `AdministratorAccess` in AWS does not automatically grant Kubernetes cluster-admin, and Kubernetes cluster-admin does not automatically grant AWS account administration.

| Role | AWS permissions to consider | Kubernetes permissions to consider |
| --- | --- | --- |
| Terraform/platform developer | Read the relevant account resources for plans; create/update only the infrastructure managed by this stack in the approved environment (EKS, VPC/EC2, subnets/routes/NAT, security groups, node groups, and the IAM roles/policy attachments this Terraform creates). Constrain IAM role creation/attachment and `iam:PassRole` to the named EKS control-plane and node roles and required AWS services. Read/write only the environment's Terraform state object and its S3 lockfile; allow bucket listing only as required. Add KMS key use only if the backend uses a customer-managed key. Normally allow plan and reviewed PRs; restrict production apply/destroy separately. | A developer changing Terraform may need no routine `kubectl` access. If they deploy applications, give access only to the assigned namespace and required resources/actions. Do not grant `system:masters` for Terraform work. |
| Application developer | Usually no AWS infrastructure mutation rights. Allow `eks:DescribeCluster` if needed to configure kubeconfig; grant artifact/log access only where required. Do not grant shared Terraform state access unless the person also performs Terraform work. | Namespace-scoped read/write for application resources they own, such as Deployments, Services, ConfigMaps, and permitted Jobs. Avoid access to Secrets unless there is a documented need; do not grant cluster-wide roles, RBAC administration, or node access by default. |
| Second cluster administrator | A separate, named administrator role with only the AWS permissions needed for the agreed operational duties. For emergency recovery, use a controlled break-glass role with MFA/SSO, alerting, audit logging, and periodic access review rather than sharing credentials. AWS account-wide administrator rights should be a distinct, explicitly approved permission set. | A dedicated EKS administrator access entry and cluster-admin permissions only if the operational responsibility truly requires full cluster control. Keep this principal separate from the primary administrator and developer identities; test it before relying on it for recovery. |
| Observer / analyst | Read-only AWS access to approved EKS cluster metadata, CloudWatch logs/metrics, and (if needed) Cost Explorer and billing views. Do not allow infrastructure mutation, Terraform state writes, or access to secrets. | Read-only view of approved namespaces and resources. Prefer `AmazonEKSViewPolicy` associated at the required namespace scope, or equivalent RBAC. EKS view access is not intended to expose Kubernetes Secrets; verify the selected policy/scope against the information classification. No create/update/delete, `exec`, port-forward, or RBAC changes unless separately approved. |
| CI/CD deployer | A dedicated workload role assumed by the pipeline, with no human access keys. Allow only required cluster discovery/token-authentication operations and artifact access; do not grant Terraform state or infrastructure mutation permissions to an application deployment role. | Namespace-scoped deployment permissions for the pipeline's application. Keep separate from human developers and cluster administrators; do not grant cluster-admin for ordinary application releases. |
| Security / compliance auditor | Read-only access to approved IAM/EKS configuration, CloudTrail, Config, security findings, and audit logs. Protect sensitive log content and restrict account-wide data visibility as required. No resource mutation or Terraform state write access by default. | Read-only access to the resources and audit information in scope. Use a purpose-built role; do not assume that Kubernetes view permissions include all audit events or AWS control-plane logs. |
| Network / infrastructure operator | Permissions scoped to VPC, routing, endpoints, security groups, and related network resources they own. Avoid IAM and cluster-admin privileges unless separately required. | Normally no Kubernetes write access. Provide read-only cluster/network diagnostics if required by the on-call responsibility. |
| IAM / identity administrator | Manage identity-provider integration, permission-set assignments, IAM roles/policies, and EKS access entries according to separation-of-duties controls. Scope changes and require review; do not use this role for routine application deployment. | Access-entry administration is an AWS control-plane task. Kubernetes RBAC changes still require an authorized Kubernetes administrator unless those changes are managed through reviewed Terraform/provider configuration. |

For this repository, Terraform creates IAM roles for EKS and EC2 nodes and attaches AWS policies. Therefore, a Terraform apply identity needs carefully scoped IAM permissions in addition to VPC/EKS permissions; a generic read-only or developer policy will not be sufficient to provision the stack. Derive and test the exact actions from the reviewed plan and AWS authorization errors, then constrain them by resource ARN, environment tags, permissions boundaries, and `iam:PassRole` conditions where AWS supports those controls. Do not solve missing permissions by attaching unrestricted `AdministratorAccess`.

For EKS access policies, AWS provides managed Kubernetes permission sets such as `AmazonEKSViewPolicy`, `AmazonEKSEditPolicy`, `AmazonEKSAdminPolicy`, and `AmazonEKSClusterAdminPolicy`. These are Kubernetes permissions, not substitutes for AWS IAM permissions to manage infrastructure. Prefer namespace-scoped associations where supported and appropriate; review the policy's actual allowed actions before assignment. Alternatively, map the access entry to Kubernetes groups and manage equivalent Role/RoleBinding rules through reviewed manifests or Terraform. Avoid granting both broad EKS access policies and broad Kubernetes groups without a clear reason.

Suggested separation for a small team: give the Terraform contributor development-only infrastructure/state permissions and namespace-scoped deployment access if needed; give the second administrator a separately authenticated, tested cluster-admin role with audited break-glass handling; give the observer/analyst read-only EKS and monitoring access. Promote permissions only for an approved task and remove temporary elevation afterward.

Use the IAM role ARN returned by `aws sts get-caller-identity` as the access-entry principal. For assumed roles, use the stable IAM role ARN, not the temporary `arn:aws:sts::...:assumed-role/...` session ARN.

## 3. Set up the contributor's workstation

Install Git, Terraform (version 1.5 or later), AWS CLI v2, and `kubectl`. Clone the repository using the Git host's normal authentication method, then create a feature branch from the correct environment branch:

```sh
git clone <repository-url>
cd <repository-directory>
git switch dev
git pull --ff-only
git switch -c feature/<short-description>
```

Use `staging` only when the task is specifically approved for staging. Do not run the environment wrapper from a feature branch: it accepts only the `dev` and `staging` branch names because the branch selects both the variable file and remote state key. To validate and create a read-only development plan from a feature branch, explicitly pin the development backend key and variable file:

```sh
terraform fmt -check -recursive
terraform init -reconfigure \
  -backend-config="key=dev/eks-env/terraform.tfstate"
terraform validate
terraform plan -var-file=environments/dev.tfvars
```

This still requires the contributor to have permission to read the development state and AWS resources. Inspect the plan and confirm its account and environment; do not apply from the feature branch. For staging, use the staging key and staging variable file only after approval.

### Configure the contributor's own AWS credentials

For AWS IAM Identity Center, configure a named profile and sign in:

```sh
aws configure sso --profile collaborator
aws sso login --profile collaborator
aws sts get-caller-identity --profile collaborator
```

The returned account and ARN must be the approved account and role. Never commit credential files, access keys, session tokens, or real `.tfvars` files.

There is a repository-specific profile constraint to address before running Terraform: `backend.tf` explicitly selects profile `chuks`, and the checked-in environment examples set `aws_profile = "chuks"`. A collaborator can configure their own authorized AWS SSO identity under the local profile name `chuks`, or the team can change the backend/provider configuration to use a configurable profile or the standard credential chain. The profile label `chuks` does not mean they should use another person's credentials. Do not edit shared Terraform settings just to hide this local setup constraint, and do not apply until the active AWS identity has been verified.

The contributor should create their ignored local environment file from the matching example, preserve the required `environment` value, and set `aws_profile` to the local profile they will use:

```sh
cp environments/dev.tfvars.example environments/dev.tfvars
```

Review `environments/dev.tfvars` locally. It is ignored by Git; do not add it to a commit. The backend profile remains separately configured in `backend.tf`, as described above.

## 4. Grant Kubernetes access

First inspect the cluster and its authentication mode using an existing authorized operator identity:

```sh
aws eks describe-cluster \
  --region us-east-1 \
  --name dev-eks \
  --query 'cluster.{status:status,version:version,authenticationMode:accessConfig.authenticationMode}'
```

The cluster owner should use EKS access entries when the cluster authentication mode supports them. If the cluster is still using only the legacy `CONFIG_MAP` mode, follow the team's planned migration procedure or use the existing `aws-auth` process; do not assume `create-access-entry` will work without the required authentication mode. Manage authentication-mode changes and access entries through Terraform for durable, reviewable access wherever possible.

For an EKS access-entry setup, the owner can create an entry for the contributor's IAM role and map it to a group. This example shows the CLI shape only; use the actual account ID and approved role ARN, and prefer adding the equivalent resource to Terraform so it is tracked:

```sh
aws eks create-access-entry \
  --cluster-name dev-eks \
  --region us-east-1 \
  --principal-arn arn:aws:iam::<account-id>:role/<contributor-role> \
  --type STANDARD \
  --kubernetes-groups developers \
  --kubernetes-username <contributor-name>
```

An access entry authenticates/maps the IAM principal; it does not by itself grant Kubernetes permissions when using Kubernetes groups. A cluster administrator must bind the `developers` group to a least-privilege Kubernetes `Role` in the application's namespace (or another deliberately scoped role). Do not bind all developers to `system:masters` or `cluster-admin` merely to make initial access work.

If the task genuinely requires cluster-wide administration, the owner should approve that separately and use a dedicated administrator group/role, with a reviewed `ClusterRoleBinding` and an audit trail. The contributor's personal AWS administrative permission is not a reason to grant cluster-admin.

The current module has no Terraform-managed user access resources. Until that is implemented, an authorized cluster administrator must perform the approved access-entry/RBAC setup. The existing [Identity and RBAC implementation guide](IDENTITY-RBAC-IMPLEMENTATION.md) explains the identity/RBAC distinction and includes example commands. Avoid untracked one-off changes for long-term access: they can be lost, drift from Terraform, or make future access difficult to audit.

## 5. Connect and verify as the contributor

On the contributor's machine, verify the active AWS role and update their local kubeconfig. For the profile named `collaborator`:

```sh
aws sts get-caller-identity --profile collaborator
aws eks describe-cluster \
  --region us-east-1 \
  --name dev-eks \
  --profile collaborator
aws eks update-kubeconfig \
  --region us-east-1 \
  --name dev-eks \
  --profile collaborator \
  --alias dev-eks-collaborator
kubectl config use-context dev-eks-collaborator
kubectl auth whoami
kubectl auth can-i get pods -n <application-namespace>
kubectl auth can-i create deployments.apps -n <application-namespace>
kubectl get pods -n <application-namespace>
```

The profile must correspond to the same IAM role ARN configured in the access entry. `describe-cluster` access alone is not proof of Kubernetes access. `kubectl auth whoami` should report the mapped identity/groups; `kubectl auth can-i` should return `yes` only for the approved actions.

If `kubectl` reports `Unauthorized`, confirm the AWS identity, kubeconfig context/profile, and EKS mapping. If it reports `Forbidden`, authentication probably succeeded but the Kubernetes role binding does not permit that operation. If it cannot connect to the endpoint, check the endpoint's public CIDR allowlist and whether the contributor's current network address is allowed. Do not solve any of these errors by granting blanket administrator access.

## 6. Collaborate on Terraform safely

Use a pull request for every change to Terraform, Kubernetes access, or deployment configuration:

1. Pull the latest `dev` branch and create a task-specific feature branch.
2. Keep each change focused. Do not change cluster access mode, IAM policies, network exposure, or node sizing without explaining the impact in the pull request.
3. Run formatting and validation locally:

   ```sh
   terraform fmt -check -recursive
   terraform validate
   ```

4. Open a pull request that states the purpose, affected environment, expected resources, risks/costs, validation performed, and rollback considerations. Include plan output where the team process permits, but redact account-sensitive details.
5. Have another authorized contributor review the code and Terraform plan. A reviewer must verify the environment, AWS account, backend state key, and any resource replacements/deletions.
6. Merge only through the agreed review process. Apply infrastructure from the `dev` or `staging` environment branch after the change is merged and the final plan is reviewed.
7. Coordinate applies. The S3 lockfile prevents simultaneous Terraform state operations for the same state, but it does not make competing code changes safe or replace plan review. Do not force-unlock state unless an operator has confirmed a stale lock and approved the recovery.
8. Never run `terraform destroy`, change backend keys, or apply to staging without explicit approval.

For Kubernetes application manifests, use a separate reviewed pull request and deploy only to the namespace assigned to the contributor. Keep credentials in an approved secret manager, not in manifests or Git. Application workloads should use their own Kubernetes ServiceAccount and workload identity rather than the contributor's AWS identity.

## 7. Access review and offboarding

When the collaboration ends or responsibilities change, remove the contributor's EKS access entry (or legacy mapping), namespace RoleBinding, repository access, and AWS role assignment as appropriate. Confirm that no shared credentials were created, rotate any credentials that may have been exposed, and retain infrastructure changes and access decisions in version control/audit records.

## Repository-specific follow-up

Before relying on this setup for a team, update the Terraform module to manage the chosen EKS authentication mode, access entries, and scoped Kubernetes permissions. Also remove the hard-coded backend profile in favor of a documented local credential-chain/profile approach. Review these changes carefully against the existing cluster and state before applying; changing authentication mode or access ownership can affect operator access.