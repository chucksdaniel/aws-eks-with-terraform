# EKS Developer, CI/CD, and Administrator Identity and RBAC Guide

## 1. Core principles

A Kubernetes access request requires three separate controls:

```text
AWS IAM identity or another trusted identity
        |
        v
Authentication to EKS
        |
        v
Kubernetes username and groups
        |
        v
RBAC RoleBinding or ClusterRoleBinding
        |
        v
Kubernetes API operation
```

The user credentials must have the following properties:

1. A valid AWS IAM identity or equivalent trusted identity.
2. Permission to assume the identity used by the developer or automation.
3. An EKS access entry or legacy aws-auth mapping to a Kubernetes identity.
4. Kubernetes RBAC permissions matching the requested tasks.

A credential with AWS administrator access is not automatically a Kubernetes administrator. It becomes Kubernetes administrator only when the associated AWS principal is mapped to a Kubernetes identity with an RBAC binding, such as `system:masters` → `cluster-admin`.

In practice, this means two things:

1. The AWS principal must be accepted by the EKS authentication mechanism.
2. The authenticated principal must be mapped to a Kubernetes username or group that has an RBAC binding.

The AWS administrator permission controls AWS API access. It does not by itself grant access to the Kubernetes API. For example, an IAM user may be allowed to modify EKS clusters but still have no mapping to any Kubernetes user or group. Kubernetes then cannot identify that user as a valid cluster user and returns an authentication error.

A Kubernetes service account is also not the same as an AWS IAM credential:

- An **AWS IAM role** authenticates the CI/CD runner or deployment tool.
- A **Kubernetes ServiceAccount** authenticates the application workload inside the cluster.
- A **RoleBinding** authorizes a Kubernetes user or group to perform kubectl operations.
- A **Pod identity** or IAM role association authorizes the application workload to access AWS resources.

These are separate identities and should normally be different.

### What the `Unauthorized` error means

The command:

```sh
kubectl get ns
```

returned:

```text
error: You must be logged in to the server (Unauthorized)
```

This is generally an authentication failure from the Kubernetes API server. It is not normally the result of an insufficient RBAC rule.

There are three common causes:

1. **The AWS principal is not mapped to Kubernetes.** The AWS identity is valid, but it has no EKS access entry or aws-auth mapping. The API server has no Kubernetes username or group to use.
2. **The kubeconfig is using the wrong identity or cluster context.** The AWS CLI may be using a different profile from the one represented by the kubeconfig exec block.
3. **The identity is mapped to a Kubernetes identity but not an RBAC binding.** The Kubernetes identity may be authenticated but has no permissions. In that case, the error is commonly `Forbidden`, not `Unauthorized`.

The distinction is:

| Result | Meaning | Typical command |
|---|---|---|
| `Unauthorized` or `You must be logged in to the server` | Authentication failed or identity was not recognized | `kubectl auth whoami` |
| `Forbidden` | Identity was authenticated, but RBAC denied the operation | `kubectl auth can-i` |
| `connection refused` or `connection reset` | Cluster endpoint, network, or firewall issue | `kubectl config view` and `kubectl get nodes` |

### How to diagnosis the error

Run these commands in order. Replace the profile and cluster names with the values for the environment.

#### 1. Verify the AWS identity

```sh
aws sts get-caller-identity --profile <profile-name>
```

The returned ARN must be the exact principal configured in the EKS access entry or aws-auth mapping.

For example:

```text
ARN: arn:aws:iam::123456789012:role/eks-development/cluster-admin
```

The profile may be a role, an IAM user, or an SSO role. The AWS console can show the role ARN, but the identity must be verified through the AWS CLI.

#### 2. Verify the kubeconfig context and authentication command

```sh
kubectl config current-context
kubectl config view --minify -o jsonpath='{.context.cluster}'
kubectl config view --minify -o jsonpath='{.users[0].user.exec.command}'
kubectl config view --minify -o jsonpath='{.users[0].user.exec.args}'
```

The current context must point to the intended EKS cluster. If the kubeconfig contains an exec authentication block, it must use the AWS profile that corresponds to the AWS identity you want to use.

The generated kubeconfig should include a user such as:

```yaml
users:
  - name: arn:aws:iam::123456789012:role/eks-development/cluster-admin
    user:
      exec:
        apiVersion: client.authentication.k8s.io/v1beta1
        command: aws
        args:
          - eks
          - get-token
          - --cluster-name
          - dev-eks
          - --region
          - us-east-1
```

If the profile is not embedded in the exec configuration, kubectl will use the current AWS profile from the AWS CLI credential chain.

#### 3. Verify the active Kubernetes identity

```sh
kubectl auth whoami
```

If this command returns `Unauthorized`, the cluster does not recognize the authenticated principal or kubeconfig is not using the expected identity.

A correct identity should look similar to:

```text
Username: cluster-admin-user
Groups: [cluster-admins system:authenticated]
```

A user may still be authenticated without having any permissions. In that case, `kubectl auth whoami` may succeed while `kubectl get ns` returns `Forbidden`.

#### 4. Verify the EKS access entry

For an access-entry cluster:

```sh
aws eks list-access-entries \
  --cluster-name dev-eks \
  --region us-east-1 \
  --output table
```

The access entry must contain the exact AWS principal ARN and a Kubernetes username or group.

For a legacy aws-auth cluster:

```sh
kubectl get configmap aws-auth -n kube-system -o yaml
```

For the current workspace, the observed `aws-auth` ConfigMap contained a node-role mapping for `system:node`, but it did not contain a developer or administrator user mapping. Therefore, an AWS administrator credential must not be assumed to work in Kubernetes unless the principal is mapped through EKS access entries or a valid aws-auth mapping.

#### 5. Verify the RBAC binding

```sh
kubectl get clusterrolebinding cluster-admin-operator -o yaml
kubectl get rolebinding application-deployer-binding -n my-application -o yaml
kubectl get clusterrole cluster-admin -o yaml
```

The subject must match the Kubernetes username or group returned by `kubectl auth whoami`.

For example, a RoleBinding containing:

```yaml
subjects:
  - kind: Group
    name: developers
```

will only work when the authenticated identity belongs to the `developers` group.

### Example: AWS administrator credential that is not mapped

Assume an AWS administrator role exists:

```text
arn:aws:iam::123456789012:role/eks-development/cluster-admin
```

The role is valid for AWS APIs, but the EKS access entry does not contain this principal. The developer runs:

```sh
aws sts get-caller-identity --profile cluster-admin
kubectl get ns
```

The AWS identity is valid, but kubectl cannot identify the principal as a Kubernetes user. The result is:

```text
error: You must be logged in to the server (Unauthorized)
```

The correct sequence is:

1. Create or update the EKS access entry for the administrator role.
2. Map the IAM principal to a Kubernetes username and group.
3. Create a ClusterRoleBinding for the group.
4. Ensure the kubeconfig uses the correct profile.
5. Run `kubectl auth whoami`.
6. Run `kubectl auth can-i`.

Example access entry:

```sh
aws eks create-access-entry \
  --cluster-name dev-eks \
  --region us-east-1 \
  --principal-arn arn:aws:iam::123456789012:role/eks-development/cluster-admin \
  --type STANDARD \
  --kubernetes-groups cluster-admins \
  --kubernetes-username cluster-admin-user
```

Example ClusterRoleBinding:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: cluster-admin-operator
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
  - kind: Group
    name: cluster-admins
```

After configuration:

```sh
aws eks update-kubeconfig \
  --region us-east-1 \
  --name dev-eks \
  --profile cluster-admin

kubectl auth whoami
kubectl auth can-i --all-namespaces create clusterroles
kubectl get ns
```

The policy should now permit the administrator identity to access the cluster.

### Example: AWS administrator credential that is mapped but has no RBAC permission

Suppose the IAM principal is correctly mapped to the Kubernetes group `developers` but no RoleBinding exists for that group. The request is authenticated, but the operation is denied through RBAC:

```text
Error from server (Forbidden): deployments.apps "my-app" is forbidden: user "developer-alice" cannot create resource "deployments" in API group "apps" in the namespace "my-application"
```

The proper response is to create and bind the Role. The AWS principal itself does not need to become cluster-admin; it only needs the correct Kubernetes identity and namespace-scoped RBAC.

### Important operational rule

Do not use the AWS administrator role to test a developer role. Test each identity independently:

```sh
aws sts get-caller-identity --profile developer
kubectl auth whoami
kubectl auth can-i -n my-application create deployments.apps

aws sts get-caller-identity --profile cluster-admin
kubectl auth whoami
kubectl auth can-i --all-namespaces create clusterroles
```

This demonstrates the difference between an AWS identity, an EKS identity mapping, and Kubernetes RBAC authorization.

---

## 2. Recommended identity model

| Identity | AWS identity | Kubernetes identity | Purpose | RBAC scope |
|---|---|---|---|---|
| Developer | IAM role or SSO role | `developer-alice` and `developers` group | Deploy and operate applications | Namespace-scoped Role |
| CI/CD pipeline | IAM role used by the pipeline | `cicd-deployer` and `cicd-deployers` group | Create/update application manifests | Namespace-scoped Role or one dedicated ClusterRole |
| Administrator | IAM admin role | `cluster-admin-user` and `cluster-admins` group | Cluster administration | ClusterRoleBinding to cluster-admin |
| Application workload | Kubernetes ServiceAccount | `application-service-account` | Access AWS resources or API services | Service account token and workload identity |

Avoid using the same AWS IAM principal for a developer, CI/CD pipeline, and administrator. Each role should have a separate identity, resource scope, and audit record.

---

## 3. Required AWS credential permissions

### 3.1 Developer credential

A developer IAM role should have only the AWS permissions needed to authenticate and perform the required EKS operations.

For a modern EKS access-entry setup, the principal must:

- Be able to assume the IAM role through the developer's identity provider.
- Be the exact principal referenced by the EKS access entry.
- Be able to obtain an EKS token through the AWS CLI or a compatible client.
- Have the permissions required by the AWS organizations' SSO or role-assumption policy.

Example SSO or trust policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::<account-id>:saml-provider/EnterpriseSSO"
      },
      "Action": "sts:AssumeRoleWithSAML",
      "Condition": {
        "StringEquals": {
          "sts:RoleSessionNamePattern": "developer-.*"
        }
      }
    }
  ]
}
```

The AWS IAM role itself should not have broad `iam:*` or `eks:*` permissions unless the developer's actual task requires them.

For a Kubernetes credential, the user should use an access entry and an EKS token. The EKS API server validates the principal and maps it to Kubernetes identity. An another AWS API permission is not required to call the Kubernetes API once the EKS access entry is configured.

### 3.2 CI/CD credential

The CI/CD pipeline should use a dedicated AWS IAM role. The role should be assumed by the CI/CD platform, not stored as a long-lived secret in the repository.

Example trust relationship:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::<account-id>:role/ci-cd-runner"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

The CI/CD role should be able to:

- Use the EKS token API through the AWS SDK or CLI.
- Read the cluster metadata when required.
- Apply Kubernetes manifests through kubectl.
- Access the deployment repository or artifact store.

The CI/CD credential should not have cluster-admin access unless it is a trusted cluster administrator. A pipeline generally needs only the permissions required to deploy to its assigned namespace.

### 3.3 Administrator credential

A cluster administrator role should be assigned only to trusted operators. It should be separate from the developer and CI/CD roles.

An administrator credential normally needs:

- An EKS access entry mapping to a dedicated Kubernetes group.
- A ClusterRoleBinding to the built-in `cluster-admin` role.
- AWS admin permissions only where required for cluster-level infrastructure operations.
- A documented break-glass process and audit trail.

Do not use a cluster-admin role for automated application deployment.

---

## 4. Configure the developer identity

### 4.1 Create the IAM role

Assume a role formatted as:

```text
arn:aws:iam::<account-id>:role/eks-development/developer-alice
```

Recommended IAM permissions:

- EKS token or cluster access through the assigned access entry.
- Permission to read the EKS cluster metadata if the workflow requires it.
- Permission to assume the role through the developer's SSO or enterprise identity provider.

An example policy for a deployment workflow is:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "sts:GetCallerIdentity"
      ],
      "Resource": "*"
    }
  ]
}
```

Do not add this policy merely to make Kubernetes work. The AWS IAM role is authenticated by the access entry; the Kubernetes RBAC role performs the actual API authorization.

### 4.2 Create the EKS access entry

```sh
CLUSTER_NAME="dev-eks"
REGION="us-east-1"
DEVELOPER_ROLE_ARN="arn:aws:iam::<account-id>:role/eks-development/developer-alice"

aws eks create-access-entry \
  --cluster-name "$CLUSTER_NAME" \
  --region "$REGION" \
  --principal-arn "$DEVELOPER_ROLE_ARN" \
  --type STANDARD \
  --kubernetes-groups developers \
  --kubernetes-username developer-alice
```

If the developer is using an AWS IAM user instead of a role, use the IAM user's ARN:

```sh
aws eks create-access-entry \
  --cluster-name dev-eks \
  --region us-east-1 \
  --principal-arn arn:aws:iam::<account-id>:user/developer-alice \
  --type STANDARD \
  --kubernetes-groups developers \
  --kubernetes-username developer-alice
```

If the cluster is using a legacy aws-auth setup, create a mapUsers entry instead:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: aws-auth
  namespace: kube-system
data:
  mapUsers: |
    - userarn: arn:aws:iam::<account-id>:role/eks-development/developer-alice
      username: developer-alice
      groups:
        - developers
```

Do not configure both access entries and aws-auth for the same principal unless the cluster design explicitly requires both.

### 4.3 Create the developer namespace and Role

Create a dedicated namespace:

```sh
kubectl create namespace my-application
```

Create a Role:

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
```

Create the RoleBinding:

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
  - kind: Group
    name: developers
```

Apply the resources:

```sh
kubectl apply -f developer-rbac.yaml
kubectl get role application-deployer -n my-application -o yaml
kubectl get rolebinding application-deployer-binding -n my-application -o yaml
```

### 4.4 Configure the developer's kubeconfig

The developer should log in through AWS SSO or an enterprise identity provider, then configure the cluster context:

```sh
aws sts get-caller-identity --profile developer
aws eks update-kubeconfig \
  --region us-east-1 \
  --name dev-eks \
  --profile developer

kubectl config current-context
kubectl auth whoami
```

The command must produce a Kubernetes username and group matching the RoleBinding subject. For example:

```text
Username: developer-alice
Groups: developers, system:authenticated
```

Note that `system:authenticated` is a general authenticated-user group. It does not provide application deployment permissions by itself.

Validate the effective permissions:

```sh
kubectl auth can-i -n my-application create deployments.apps
kubectl auth can-i -n my-application get deployments.apps
kubectl auth can-i -n my-application create secrets
kubectl auth can-i --all-namespaces create clusterroles
```

Expected results:

- `create deployments.apps`: yes
- `get deployments.apps`: yes
- `create secrets`: no if the Role does not include secrets
- `create clusterroles`: no for a namespace-scoped developer

### 4.5 Developer deployment example

The developer can now perform application tasks:

```sh
kubectl create namespace my-application
kubectl apply -f deployment.yaml
kubectl apply -f service.yaml
kubectl rollout status deployment/my-application -n my-application
kubectl get pods -n my-application
kubectl get events -n my-application --sort-by=.lastTimestamp
```

The developer can use `kubectl auth can-i` before each operation to validate the role.

---

## 5. Configure the CI/CD pipeline identity

The CI/CD pipeline should use a distinct AWS IAM role and should not use a developer credential.

### 5.1 IAM role trust

Create a role named:

```text
arn:aws:iam::<account-id>:role/eks-development/cicd-deployer
```

The CI/CD platform should assume that role. The role must be granted only the AWS permissions required to obtain the EKS token and access the deployment repository.

Secure example trust policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::<account-id>:role/ci-cd-runner"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

### 5.2 EKS access entry

Map the CI/CD role to a dedicated Kubernetes group:

```sh
aws eks create-access-entry \
  --cluster-name dev-eks \
  --region us-east-1 \
  --principal-arn arn:aws:iam::<account-id>:role/eks-development/cicd-deployer \
  --type STANDARD \
  --kubernetes-groups cicd-deployers \
  --kubernetes-username cicd-deployer
```

A CI/CD identity should not normally be mapped to `system:masters`.

### 5.3 CI/CD Role and RoleBinding

Create a Role for deployment operations:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: cicd-deployer
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

Bind the group:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: cicd-deployer-binding
  namespace: my-application
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: cicd-deployer
subjects:
  - kind: Group
    name: cicd-deployers
```

### 5.4 CI/CD authentication example

The CI/CD runner should use the AWS IAM role through the automation platform. A typical pipeline configuration is:

```yaml
credentials:
  aws_role_arn: arn:aws:iam::<account-id>:role/eks-development/cicd-deployer
  region: us-east-1
  cluster_name: dev-eks
```

The pipeline obtains the EKS token:

```sh
aws sts assume-role \
  --role-arn arn:aws:iam::<account-id>:role/eks-development/cicd-deployer \
  --role-session-name cicd-deployment

aws eks get-token \
  --cluster-name dev-eks \
  --region us-east-1
```

The CI/CD pipeline should avoid putting the AWS credentials in a source-controlled file. It should use:

- OIDC federation.
- AWS IAM role assumption.
- A CI/CD secret manager.
- A short-lived credential provider.

### 5.5 CI/CD Application ServiceAccount

The CI/CD pipeline and the application workload need different service accounts.

Create a deployment service account for the application:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: application-service-account
  namespace: my-application
```

Use the ServiceAccount in the application pod:

```yaml
spec:
  template:
    spec:
      serviceAccountName: application-service-account
```

Associate the application ServiceAccount with the AWS workload identity:

- EKS Pod Identity
- IAM Roles for Service Accounts, or
- A dedicated AWS IAM role with a trust relationship to the Kubernetes service account

The CI/CD identity should be able to create or update the application workload. The application workload identity should be separately scoped for the AWS resources it needs.

### 5.6 CI/CD authorization checks

```sh
kubectl auth whoami
kubectl auth can-i -n my-application create deployments.apps
kubectl auth can-i -n my-application update deployments.apps
kubectl auth can-i -n my-application get secrets
kubectl auth can-i --all-namespaces create clusterroles
```

A CI/CD pipeline should receive `yes` only for operations in its assigned namespace and should receive `no` for cluster-wide administrative operations.

---

## 6. Configure the administrator identity

Only trusted operators should receive administrator access.

### 6.1 Administrator AWS role

Create a separate role:

```text
arn:aws:iam::<account-id>:role/eks-development/cluster-admin
```

Configure the role trust relationship for the operator or enterprise identity provider. The administrator role should not be used by the application or CI/CD pipeline.

### 6.2 Administrator EKS access entry

```sh
aws eks create-access-entry \
  --cluster-name dev-eks \
  --region us-east-1 \
  --principal-arn arn:aws:iam::<account-id>:role/eks-development/cluster-admin \
  --type STANDARD \
  --kubernetes-groups cluster-admins \
  --kubernetes-username cluster-admin-user
```

### 6.3 Administrator ClusterRoleBinding

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: cluster-admin-operator
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
  - kind: Group
    name: cluster-admins
```

Apply the binding:

```sh
kubectl apply -f administrator-rbac.yaml
kubectl auth can-i --all-namespaces create clusterroles
kubectl auth can-i --all-namespaces delete namespaces
```

A cluster administrator normally receives `yes` for both commands. This is intentionally broad and should be used only for trusted operators.

### 6.4 Administrator kubeconfig

```sh
aws sts get-caller-identity --profile cluster-admin
aws eks update-kubeconfig \
  --region us-east-1 \
  --name dev-eks \
  --profile cluster-admin
kubectl auth whoami
kubectl get nodes
```

The administrator identity should be visible as the configured Kubernetes username and group. If the identity is mapped as `cluster-admin-user` and `cluster-admins`, the ClusterRoleBinding will grant the built-in cluster-admin permissions.

---

## 7. Complete role assignment table

| Identity | AWS role | EKS access entry group | Kubernetes identity | RBAC resource | Allowed operations |
|---|---|---|---|---|---|
| Developer | `eks-development/developer-alice` | `developers` | `developer-alice` | Role + RoleBinding in `my-application` | Create/update application resources in the namespace |
| CI/CD | `eks-development/cicd-deployer` | `cicd-deployers` | `cicd-deployer` | Role + RoleBinding in deployment namespaces | Deploy and update named workloads |
| Administrator | `eks-development/cluster-admin` | `cluster-admins` | `cluster-admin-user` | ClusterRoleBinding to `cluster-admin` | Cluster-wide administrative operations |
| Application workload | Kubernetes ServiceAccount | Workload identity or Pod identity | `application-service-account` | Kubernetes service account and AWS trust policy | Required AWS API access only |

---

## 8. Authentication example using AWS IAM SSO

Use an AWS SSO profile for the developer:

```sh
aws sso login
aws configure sso profile --profile developer
```

Use the role through the profile:

```sh
aws sts get-caller-identity --profile developer
```

Configure kubeconfig:

```sh
aws eks update-kubeconfig \
  --region us-east-1 \
  --name dev-eks \
  --profile developer
```

Verify the identity:

```sh
kubectl auth whoami
kubectl auth can-i -n my-application create deployments.apps
```

The AWS IAM role must be the principal configured in the EKS access entry. The developer does not need a separately created Kubernetes token if the EKS token-based authentication is working correctly.

---

## 9. Authentication example using a CI/CD OIDC provider

For CI/CD, prefer short-lived AWS credentials from an OpenID Connect provider rather than a long-lived AWS access key.

Example pipeline assumptions:

```text
GitHub Actions or CI/CD OIDC provider
    ->
AWS IAM role: eks-development/cicd-deployer
    ->
EKS access entry: cicd-deployers
    ->
Kubernetes group: cicd-deployers
    ->
Namespace RoleBinding: cicd-deployer
```

The pipeline should execute:

```sh
aws eks get-token --cluster-name dev-eks --region us-east-1
kubectl auth whoami
kubectl apply -f deployment.yaml
```

The pipeline should use a CI/CD runner identity with a short-lived token. Do not store long-lived AWS access keys in the pipeline repository or Kubernetes secrets.

---

## 10. On-prem Kubernetes equivalent

On-prem Kubernetes uses the same RBAC model, but authentication is supplied by another system.

```text
Developer certificate or OIDC identity
    ->
Kubernetes API server authentication
    ->
Kubernetes username/group
    ->
RoleBinding or ClusterRoleBinding
    ->
Kubernetes API authorization
```

For an on-prem developer:

1. Create a named user in the corporate identity provider.
2. Create a client certificate, token, or OIDC identity.
3. Configure the kubeconfig with the API server endpoint and CA certificate.
4. Map the user to a Kubernetes group or username.
5. Create a Role and RoleBinding in the application namespace.
6. Verify the identity with kubectl auth whoami.
7. Verify permissions with kubectl auth can-i.

Example on-prem kubeconfig:

```yaml
apiVersion: v1
clusters:
  - name: on-prem
    cluster:
      server: https://kubernetes.example.com:6443
      certificate-authority-data: <base64-encoded-ca>
contexts:
  - name: developer
    context:
      cluster: on-prem
      user: alice
current-context: developer
users:
  - name: alice
    user:
      token: <short-lived-token>
```

The role binding is identical to EKS:

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
    name: alice
```

The difference is that `alice` is authenticated through the on-prem identity provider and not through an AWS IAM role.

---

## 11. Security checklist

- [ ] Each developer and CI/CD identity is unique.
- [ ] No user shares an AWS IAM role with another developer.
- [ ] The EKS access entry maps the correct AWS principal.
- [ ] The kubeconfig uses the correct cluster, region, and IAM profile.
- [ ] The developer's Kubernetes group is not `system:masters`.
- [ ] The CI/CD pipeline uses short-lived credentials.
- [ ] The CI/CD service account is not used for application workload AWS access unless explicitly designed.
- [ ] The Role is limited to a single namespace.
- [ ] No cluster-wide RBAC is granted to normal developers.
- [ ] The administrator role is separate from application roles.
- [ ] A backup administrator exists before removing existing access.
- [ ] kubectl auth whoami is tested after every identity change.
- [ ] kubectl auth can-i is tested for every required operation.
- [ ] AWS credentials and Kubernetes tokens are stored in a secret manager.
- [ ] Access is reviewed periodically.
