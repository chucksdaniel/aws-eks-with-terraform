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

### Understanding the current pod output

The shown output contains only the `kube-system` namespace because no application workload has been deployed yet. The `kube-system` namespace is reserved for Kubernetes and EKS system components. It is not the application's namespace and should not be used for application resources.

The pods have the following purposes:

- `aws-node`: The EKS VPC CNI plugin. It manages the network interfaces used by pods and supports networking features such as VPC CNI traffic handling. The two `aws-node` pods indicate that the daemon set is running on both worker nodes.
- `kube-proxy`: The Kubernetes networking component that maintains iptables rules for Services, exposing service traffic to pods, and supporting basic Kubernetes networking behavior. The two `kube-proxy` pods indicate that the daemon set is running on both worker nodes.
- `coredns-b8cbb77dc-f8v9z` and `coredns-b8cbb77dc-qmgxb`: CoreDNS replicas that provide DNS for the cluster. They resolve service names and Kubernetes DNS records for workloads inside the cluster. The two pods are normally used for availability and load distribution.

The `READY` and `STATUS` columns show that all six pods are running and ready. The `RESTARTS` column shows zero restarts, which means these containers have not restarted during the observed period. The `AGE` values show that the system components have been running for approximately 89–98 minutes.

The current two-worker-node layout means that node-level daemons such as `aws-node` and `kube-proxy` have one pod per node. A later application Deployment will appear in its own namespace, for example `my-application`, rather than in `kube-system`.

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

### RBAC concept and how the current user is granted access

Kubernetes RBAC, or Role-Based Access Control, decides who may perform which actions on Kubernetes resources. It answers questions such as: **Who is calling? What resource are they changing? In which namespace? What operation are they trying to perform?**

The authorization flow is:

1. The client authenticates with the EKS API.
2. The authentication system converts the AWS identity into a Kubernetes username and group list.
3. Kubernetes evaluates the user's groups and identities against RBAC rules.
4. The API server either allows or rejects the request.

A simple RBAC model uses three objects:

- **Role:** describes allowed actions on resources in one namespace.
- **RoleBinding:** connects a user, group, or service account to a Role.
- **ClusterRole:** describes allowed actions across all namespaces.
- **ClusterRoleBinding:** connects a user, group, or service account to a ClusterRole.

For example, a role can allow a developer to create Deployments in one namespace:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: application-deployer
  namespace: my-application
rules:
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["get", "list", "watch", "create", "update", "patch"]
  - apiGroups: [""]
    resources: ["services"]
    verbs: ["get", "list", "watch", "create", "update", "patch"]
```

A RoleBinding grants that role to a user or group:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: application-deployer-binding
  namespace: my-application
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: application-deployer
subjects:
  - kind: User
    name: chuks
```

The RoleBinding is important because it connects the identity to permissions. A Role alone does not grant anyone access; it only defines what could be allowed. The RoleBinding applies that definition to a specific Kubernetes user or group.

The current user was checked with:

```sh
kubectl auth whoami
kubectl auth can-i create namespaces
kubectl auth can-i create deployments.apps
kubectl auth can-i create services
```

The output showed the user as `kubernetes-admin`, associated with the AWS IAM identity `chuks`, and the groups `system:masters` and `system:authenticated`. The three permission checks returned `yes`.

The observed cluster-admin grant is the built-in binding:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: cluster-admin
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
  - apiGroup: rbac.authorization.k8s.io
    kind: Group
    name: system:masters
```

This means the `system:masters` group receives the permissions of the built-in `cluster-admin` ClusterRole. The `cluster-admin` role is very broad and can manage nearly all Kubernetes resources across the cluster. It is appropriate only for trusted administrators, not for normal application deployment users.

The user is currently receiving broad access because the AWS identity is mapped into the Kubernetes `system:masters` group. The `system:authenticated` group is a general Kubernetes group for authenticated users and does not by itself grant useful permissions; it is commonly used as part of the authentication flow. The important permission decision is the explicit `system:masters` binding to `cluster-admin`.

### How permissions are granted in practice

A request such as `kubectl create deployment my-app` is evaluated as follows:

1. The AWS login supplies the user's identity to EKS.
2. The authentication method maps the AWS principal to a Kubernetes username or group.
3. Kubernetes reads the matching RoleBinding or ClusterRoleBinding.
4. The binding references a Role or ClusterRole containing the required rules.
5. The API server checks the requested resource, namespace, and verb.
6. If the rule allows it, the request succeeds; otherwise Kubernetes returns `Forbidden`.

For example, a Kubernetes API request is permission-checked against:

- Resource: `deployments`
- API group: `apps`
- Namespace: `my-application`
- Verb: `create`

A Role rule with `apiGroups: ["apps"]`, `resources: ["deployments"]`, and `verbs: ["create"]` permits that operation in the namespace where the RoleBinding is applied.

### Best-practice grant model

For an application deployment, prefer a dedicated identity and namespace rather than granting `system:masters` to the developer or automation identity.

Recommended practice:

- Create a dedicated namespace for each application or team.
- Create a Role with only the permissions needed in that namespace.
- Bind that Role to a dedicated Kubernetes user or group.
- Use a separate service account for the application workload.
- Use EKS Pod Identity or IRSA for application-specific AWS permissions.
- Use EKS access entries for AWS IAM users and roles, with Kubernetes group or RBAC mappings.
- Avoid granting the same broad `cluster-admin` role to every developer or CI/CD identity.
- Review RBAC rules regularly and grant least privilege.
- Use a separate role for read-only users, deployment operators, and administrators.

A good developer role can include only the resources needed for deployment:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: application-deployer
  namespace: my-application
rules:
  - apiGroups: [""]
    resources: ["configmaps", "secrets", "services"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["apps"]
    resources: ["deployments", "statefulsets", "daemonsets"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["apps"]
    resources: ["deployments/scale", "statefulsets/scale"]
    verbs: ["update", "patch"]
```

This is still broader than necessary for some environments. Start with only the verbs required by the application team and remove unused permissions after testing.

### Avoiding unsafe grants

Do not use `cluster-admin` for normal application deployment unless the identity is a trusted cluster administrator. Also avoid:

- Granting `*` in every API group and resource.
- Binding a broad cluster role to a shared user.
- Using a production account's root credentials for Kubernetes access.
- Granting permissions in every namespace when only one namespace is required.
- Giving application workloads the cluster-admin role.

### Current configuration recommendation

This development cluster currently has an administrative identity with `cluster-admin` access. That is useful for confirming the cluster and running initial tests, but it is not the recommended permanent deployment model.

For a production or shared environment:

1. Add an EKS access entry for the AWS IAM user or role.
2. Map that identity to a dedicated Kubernetes group or username.
3. Create a namespace-scoped Role and RoleBinding.
4. Grant only the required actions in the application namespace.
5. Create a separate service account and workload identity for the application.
6. Use least-privilege AWS IAM policies for both the deployment identity and the workload identity.
7. Review the effective permissions with `kubectl auth can-i` and `kubectl get selfsubjectaccessreviews`.

The existing `system:masters` binding should be removed or changed only after an approved administrative replacement is in place. Changing it without a tested backup identity can lock out the administrator.

### Where developer RBAC is created

A Role and RoleBinding are Kubernetes API resources. They are normally created by applying YAML with `kubectl apply`, not by Terraform unless the Terraform configuration explicitly creates them with a Kubernetes provider or a Kubernetes manifest resource.

The current repository does not contain a developer Role or RoleBinding. The working cluster currently grants the developer the built-in `cluster-admin` ClusterRole through the `system:masters` group. The `system:authenticated` group is an authenticated-user group and does not provide deployment permissions by itself.

The authorization objects can be created from YAML as follows. Replace `developer-group`, `application-deployer`, and `my-application` with values that match the environment:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: application-deployer
  namespace: my-application
rules:
  - apiGroups: [""]
    resources: ["configmaps", "services"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["apps"]
    resources: ["deployments", "statefulsets", "daemonsets"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["apps"]
    resources: ["deployments/scale", "statefulsets/scale"]
    verbs: ["update", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: application-deployer-binding
  namespace: my-application
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: application-deployer
subjects:
  - kind: Group
    name: developer-group
```

Apply the manifest:

```sh
kubectl apply -f developer-rbac.yaml
```

A RoleBinding is the connection between the permission definition and the identity. A Role alone does not grant permission. The subject name must match the Kubernetes username or group returned by `kubectl auth whoami` after the developer authenticates.

### Developer authentication flow

The AWS identity and Kubernetes RBAC are separate layers:

1. The developer logs in to AWS with an IAM user or role.
2. The AWS credentials are used to obtain an EKS token or through an EKS access entry.
3. The EKS client returns a Kubernetes username, UID, and groups.
4. The developer's Kubernetes username or group is matched to a RoleBinding or ClusterRoleBinding.
5. Kubernetes evaluates the requested operation against the Role rules.
6. The API server allows the request only when the matching RBAC rules permit it.

For a legacy `aws-auth` setup, the AWS IAM identity must be mapped to a Kubernetes username or group in the `kube-system/aws-auth` ConfigMap. The current cluster's ConfigMap contains only the node role mapping, so the developer mapping should be reviewed before relying on `aws-auth` for a new developer identity.

For an access-entry setup, the identity is configured through EKS rather than by editing the `aws-auth` ConfigMap. The access entry can provide the AWS principal, and the Kubernetes RBAC mapping can use a dedicated group or username.

The current identity can be inspected with:

```sh
kubectl auth whoami
kubectl auth can-i -n my-application create deployments.apps
kubectl auth can-i -n my-application get deployments.apps
kubectl get role application-deployer -n my-application -o yaml
kubectl get rolebinding application-deployer-binding -n my-application -o yaml
```

The `kubectl auth whoami` output should identify the exact Kubernetes username and groups that the RoleBinding subject must match. Do not bind a Role to `system:masters`; that group is already connected to the broad `cluster-admin` ClusterRole and should be removed only through an approved migration.

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
