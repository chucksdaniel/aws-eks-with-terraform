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

## 5. Connect to the EKS cluster and prepare it for application deployment

### Required client configuration

Before connecting, install and verify the required client tools:

```sh
aws --version
kubectl version --client
```

The AWS CLI must be authenticated with the intended AWS profile, and the profile must have permission to read the EKS cluster and update the local kubeconfig. The `chuks` profile in `us-east-1` is the current configuration:

```sh
aws sts get-caller-identity --profile chuks
aws eks describe-cluster \
  --region us-east-1 \
  --name dev-eks \
  --profile chuks
```

The current cluster is configured with the following working connection values:

- Cluster name: `dev-eks`
- Region: `us-east-1`
- AWS profile: `chuks`
- Kubernetes version: `1.36`
- Worker nodes: two `t3.medium` nodes, both currently `Ready`

The EKS API endpoint is public in the current Terraform configuration. The caller must still have AWS IAM permission to access the cluster and Kubernetes RBAC permission to perform the intended operations. The current Terraform does not create EKS access entries or Kubernetes RBAC rules for a team or deployment pipeline, so add those explicitly before using the cluster in a shared or production environment.

### Configure kubeconfig

Use the cluster name and current Terraform outputs to add or update the local kubeconfig entry:

```sh
CLUSTER_NAME="$(terraform output -raw eks_cluster_name)"
aws eks update-kubeconfig \
  --region us-east-1 \
  --name "$CLUSTER_NAME" \
  --profile chuks

kubectl config current-context
kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}'
kubectl get nodes
kubectl get pods --all-namespaces
```

A successful connection should show the cluster context, the EKS API server URL, and one or more `Ready` worker nodes. The live validation in this workspace successfully listed two Ready nodes using the `dev-eks` context.

### Verify Kubernetes access

Run an authorization check before deployment:

```sh
kubectl auth can-i create namespaces
kubectl auth can-i create deployments.apps
kubectl auth can-i create services
```

If the identity is authorized only for a limited role, do not grant cluster-wide privileges unnecessarily. For an application deployment, the minimum practical access normally includes:

- Create and manage a dedicated namespace.
- Create the application's Deployment, Service, ConfigMap, Secret, and related resources.
- Read required Kubernetes resources through the appropriate RBAC rules.
- Use a dedicated service account and workload identity when the application needs AWS permissions.

### Prepare the namespace and application deployment

Create a dedicated namespace for the application:

```sh
kubectl create namespace my-application
kubectl config set-context --current --namespace=my-application
```

Then deploy through the approved manifest, Helm chart, or CI/CD pipeline. A basic deployment should include:

- A Deployment or StatefulSet appropriate to the workload
- A Service when the application must be reachable internally
- Resource requests and limits
- Readiness and liveness probes
- A dedicated service account when AWS access is required
- A ConfigMap or Secret for non-sensitive configuration and secrets
- A Pod Identity or IRSA association for AWS API access
- Network policy and security controls where required

Verify the deployment manually:

```sh
kubectl get pods
kubectl describe pod <pod-name>
kubectl get events --sort-by=.lastTimestamp
kubectl rollout status deployment/my-application
kubectl get service
```

For external access, add the AWS Load Balancer Controller, ingress, DNS, TLS, and an approved public or private exposure route. The current VPC subnet tags support subnet discovery, but they do not create the controller or an application endpoint.

### Cluster access-control configuration

For a shared or production cluster, configure EKS access entries and Kubernetes RBAC rather than relying on the creator's identity. A practical pattern is:

- An administrator access entry for the platform team.
- A deployment automation access entry with only the required Kubernetes API permissions.
- A separate service account and workload identity for each application that calls AWS.
- A private API endpoint or a restricted source-IP range for remote access.
- An approved authentication and audit path for CI/CD and operators.

The current development configuration does not create these entries, so it should not be treated as a complete shared-team or production authorization model.

The public endpoint can be restricted with an EKS private access configuration or an appropriate source-IP allowlist. Do not expose the API to the entire internet when the cluster contains valuable workloads.

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
