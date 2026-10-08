# EKS Authentication and RBAC Guide

## Executive summary

Kubernetes authentication and authorization are separate processes:

- **Authentication** answers: *Who is calling?*
- **Authorization** answers: *What may that identity do?*
- **RBAC** decides the allowed actions for an authenticated Kubernetes user, group, or service account.

A developer or administrator does not become Kubernetes-accessible merely because an RBAC Role or ClusterRole exists. The caller must first authenticate with a trusted identity mechanism. For EKS, that normally means an AWS IAM user or role that can obtain an EKS token and is mapped to an EKS access entry or legacy aws-auth mapping.

Terraform credentials used to provision the cluster do not automatically grant Kubernetes access. Those credentials become Kubernetes administrators only when they are mapped to a Kubernetes identity that has an appropriate RBAC binding.

In the current cluster, the observed identity was:

- AWS principal: `arn:aws:iam::378653386746:user/chuks`
- Kubernetes username: `kubernetes-admin`
- Kubernetes groups: `system:masters` and `system:authenticated`
- Effective permission: the built-in `cluster-admin` ClusterRole through `system:masters`

That access came from an identity mapping that is not defined in this repository. The current repository contains no developer Role or RoleBinding, and the current cluster has no explicit EKS access-entry configuration in Terraform.

> Important: the developer must still have valid credentials. RBAC is not an authentication substitute. It is an authorization mechanism.

---

## 1. Authentication and authorization terminology

| Term | Purpose | Example |
|---|---|---|
| AWS IAM identity | Authenticates the person or automation to AWS | AWS IAM user, role, or federated identity |
| EKS access entry | Registers an AWS principal with EKS | IAM user or role mapped to a Kubernetes identity |
| Kubeconfig | Stores the cluster API endpoint and authentication method for kubectl | Cluster server, CA certificate, and exec authentication |
| Kubernetes user or group | Represents the authenticated identity in Kubernetes RBAC | `developer-group` or `developer-alice` |
| Role | Defines namespace-scoped permissions | Deployments and Services in one namespace |
| RoleBinding | Connects a user or group to a Role | Binds `developer-group` to `application-deployer` |
| ClusterRole | Defines cluster-wide permissions | Read-only cluster metadata |
| ClusterRoleBinding | Connects a user or group to a ClusterRole | Binds `system:masters` to `cluster-admin` |

The Kubeconfig and RBAC configuration are different files and resources:

- Kubeconfig selects the cluster and describes how to authenticate.
- EKS access entries or aws-auth map the AWS principal to a Kubernetes identity.
- Kubernetes RBAC controls what the resulting identity can do.

---

## 2. What happens to an AWS credential during a kubectl request

When a developer runs a command such as:

```sh
kubectl get nodes
```

The request follows this sequence:

1. The developer has an AWS credential in the AWS CLI credential chain, such as:
   - AWS profile
   - AWS SSO role
   - Environment credentials
   - EC2 instance metadata
   - Azure or external identity integration
2. The kubeconfig uses an EKS token command or an EKS access-entry identity.
3. The AWS CLI requests an EKS authentication token.
4. The EKS API server validates the AWS principal.
5. EKS or the legacy aws-auth mapper converts the principal into a Kubernetes username and group list.
6. Kubernetes looks for matching RoleBindings and ClusterRoleBindings.
7. The API server either allows or rejects the requested operation.

The credential is therefore needed to establish identity. Once the identity is authenticated, Kubernetes RBAC controls the action.

A static Kubernetes token or certificate can also authenticate a request, but that is different from AWS identity. It is critically important to protect such tokens because they are long-lived bearer credentials.

---

## 3. Why the provisioning AWS account can become a Kubernetes administrator

Terraform provisioning uses an AWS IAM principal with permission to manage EKS resources. That permission is an AWS permission, not a Kubernetes permission.

For example, an IAM user can have permission to:

- Create an EKS cluster.
- Create IAM roles.
- Modify a VPC.
- Call `aws eks update-kubeconfig`.

None of those permissions alone necessarily gives the user Kubernetes RBAC permissions.

The principal becomes Kubernetes administrator only when a mapping exists such as:

```text
AWS IAM user/group
        |
        v
Kubernetes username or group
        |
        v
ClusterRoleBinding or RoleBinding
        |
        v
Kubernetes API permissions
```

In this workspace, the development identity currently has access to the cluster as `kubernetes-admin` through `system:masters`. The exact mapping can be located by inspecting:

```sh
kubectl auth whoami
kubectl get clusterrolebinding cluster-admin -o yaml
kubectl get clusterrole cluster-admin -o yaml
```

The relevant mapping concept is:

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

The current user is therefore effectively a cluster administrator because the AWS identity is mapped to `system:masters` by the cluster's authentication configuration or external identity mapping.

Do not assume that changing the Terraform deployment credentials will remove the Kubernetes access. The mapping must also be changed or removed.

---

## 4. Current cluster authentication state

The current repository does not define EKS access entries or a Kubernetes developer identity mapping. The current cluster has also been observed using the legacy `aws-auth` ConfigMap for node role authentication.

The current `aws-auth` ConfigMap contains a node-role mapping similar to:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: aws-auth
  namespace: kube-system
data:
  mapRoles: |
    - rolearn: arn:aws:iam::123456789012:role/dev-eks-node-role
      username: system:node:{{EC2PrivateDNSName}}
      groups:
        - system:bootstrappers
        - system:nodes
```

That mapping is for the worker node identity. It is not a developer mapping.

The developer identity mapping is likely being supplied by a location outside the repository, such as:

- A manually edited `aws-auth` ConfigMap.
- An EKS access entry.
- A cluster-management tool.
- An external identity provider.
- An IAM role mapping created outside Terraform.

To determine the effective mapping, inspect the identity and the relevant EKS configuration:

```sh
aws sts get-caller-identity --profile chuks
kubectl auth whoami
kubectl get clusterrolebinding cluster-admin -o yaml
kubectl get configmap aws-auth -n kube-system -o yaml
```

The exact commands and output should be reviewed before changing any mapping.

---

## 5. Recommended EKS access-entry setup

Modern EKS access entries are preferred for shared environments. An access entry maps an AWS IAM principal to a Kubernetes identity.

### 5.1 Create a dedicated AWS IAM role for the developer

Create an IAM role or user for each developer or team. Do not use the account root or the Terraform deployment administrator's role for normal Kubernetes work.

For example, create an IAM role named:

```text
arn:aws:iam::<account>:role/eks-development/developer-alice
```

The role should have the AWS permissions required for the developer's work. For example, the developer may need permission to:

- Assume the role through SSO or an IdP.
- Use the EKS token API.
- Read the cluster.
- Perform Kubernetes operations permitted by RBAC.

Do not grant broad AWS administrative permissions solely to obtain Kubernetes access.

### 5.2 Create the EKS access entry

Create an access entry with the IAM principal ARN:

```sh
CLUSTER_NAME="dev-eks"
REGION="us-east-1"
DEVELOPER_ROLE_ARN="arn:aws:iam::123456789012:role/eks-development/developer-alice"

aws eks create-access-entry \
  --cluster-name "$CLUSTER_NAME" \
  --region "$REGION" \
  --principal-arn "$DEVELOPER_ROLE_ARN" \
  --type STANDARD \
  --kubernetes-groups developers \
  --kubernetes-username developer-alice
```

The exact CLI options can vary by AWS CLI and EKS version. The important behavior is that the AWS principal is matched to a Kubernetes identity.

The preferred design is a group because one group can represent a team or role:

```text
AWS IAM role: developer-alice
    |
    v
Kubernetes group: developers
    |
    v
RoleBinding: developers -> application-deployer
```

### 5.3 Create the namespace-scoped Role and RoleBinding

Create a namespace:

```sh
kubectl create namespace my-application
```

Create the Role and RoleBinding:

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
    name: developers
```

Apply the manifest:

```sh
kubectl apply -f developer-rbac.yaml
```

The RoleBinding connects the group to the Role. The Role determines the permitted actions, and the RoleBinding determines where those actions are available.

### 5.4 A developer's AWS login and kubeconfig

The developer should configure an AWS SSO profile or IAM role and then use an EKS token-based kubeconfig.

One common configuration is:

```sh
aws configure sso login
aws configure sso profile --profile developer
```

Then update kubectl authentication using the AWS CLI:

```sh
aws eks update-kubeconfig \
  --region us-east-1 \
  --name dev-eks \
  --profile developer
```

A generated kubeconfig commonly contains an exec section similar to:

```yaml
users:
  - name: arn:aws:iam::123456789012:role/eks-development/developer-alice
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

The AWS CLI will use the selected profile or credential chain when generating the token. The token contains the authenticated AWS identity and is accepted by the EKS API server.

Verify the developer's identity:

```sh
aws sts get-caller-identity --profile developer
kubectl auth whoami
kubectl auth can-i -n my-application create deployments.apps
kubectl auth can-i -n my-application get deployments.apps
```

If `kubectl auth whoami` returns the expected Kubernetes groups, the access-entry mapping is working.

### 5.5 Developer creates an application

After authentication and RBAC are working, the developer can create resources:

```sh
kubectl create namespace my-application
kubectl apply -f deployment.yaml
kubectl apply -f service.yaml
kubectl get pods -n my-application
kubectl get deployment -n my-application
kubectl get service -n my-application
```

For a deployment that needs AWS access, use a dedicated Kubernetes service account and workload identity rather than granting the developer or workload system:masters.

A typical service account configuration is:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: application-service-account
  namespace: my-application
```

Then associate the service account with an EKS Pod Identity or IAM Role for Service Accounts policy. The application workload should use that account:

```yaml
spec:
  template:
    spec:
      serviceAccountName: application-service-account
```

---

## 6. Legacy aws-auth setup

The legacy `aws-auth` method uses a ConfigMap in `kube-system` to map AWS IAM identities to Kubernetes usernames and groups.

A developer mapping looks like this:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: aws-auth
  namespace: kube-system
data:
  mapUsers: |
    - userarn: arn:aws:iam::123456789012:user/developer-alice
      username: developer-alice
      groups:
        - developers
```

The corresponding Kubernetes group must have a RoleBinding:

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

Apply the ConfigMap carefully:

```sh
kubectl apply -f aws-auth.yaml
kubectl get configmap aws-auth -n kube-system -o yaml
```

The `mapUsers` and `mapRoles` mappings are not the same as Kubernetes RBAC. They create the Kubernetes identity; the RoleBinding grants permissions to that identity.

Legacy `aws-auth` should be avoided for new clusters when EKS access entries can be used because it requires more manual configuration and is less aligned with modern EKS identity management.

---

## 7. Role, RoleBinding, ClusterRole, and ClusterRoleBinding

### Role and RoleBinding

Use a Role when permissions should apply only in one namespace:

- `Role`: defines allowed actions.
- `RoleBinding`: connects a user, group, or service account to the Role.
- Scope: one namespace.
- Example: `developers` may deploy in `my-application`.

### ClusterRole and ClusterRoleBinding

Use a ClusterRole when access should apply across namespaces:

- `ClusterRole`: defines cluster-wide actions.
- `ClusterRoleBinding`: connects a user, group, or service account to the ClusterRole.
- Scope: all namespaces.
- Example: `cluster-admin` can manage nearly all Kubernetes resources.

The built-in `cluster-admin` ClusterRole is intentionally very broad:

```sh
kubectl get clusterrole cluster-admin -o yaml
kubectl auth can-i --all-namespaces create deployments.apps
```

It should be used only for trusted administrators.

---

## 8. Creating a user and assigning a role

A practical setup is:

### Step 1: Create the AWS identity

Create a dedicated IAM user or role for the developer:

```text
AWS IAM role: arn:aws:iam::123456789012:role/eks-development/developer-alice
```

Ensure the developer can use the role through AWS SSO, an enterprise IdP, or a managed identity.

### Step 2: Create the EKS access entry

Register the principal with EKS:

```sh
aws eks create-access-entry \
  --cluster-name dev-eks \
  --region us-east-1 \
  --principal-arn arn:aws:iam::123456789012:role/eks-development/developer-alice \
  --type STANDARD \
  --kubernetes-groups developers \
  --kubernetes-username developer-alice
```

If the exact access-entry command differs by CLI version, use the AWS CLI help and preserve the principal-to-Kubernetes-identity mapping.

### Step 3: Create the namespace and Role

```sh
kubectl create namespace my-application
```

Create the Role with only the needed verbs and resources.

### Step 4: Create the RoleBinding

Bind the `developers` group to the Role:

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

### Step 5: Configure the developer

The developer logs in through AWS and uses the cluster's kubeconfig:

```sh
aws sts get-caller-identity --profile developer
aws eks update-kubeconfig --region us-east-1 --name dev-eks --profile developer
kubectl config current-context
kubectl auth whoami
```

The `kubectl auth whoami` command is the first validation that the authentication mapping is correct.

### Step 6: Test the role

```sh
kubectl auth can-i -n my-application create deployments.apps
kubectl auth can-i -n my-application get deployments.apps
kubectl auth can-i -n my-application create secrets
kubectl auth can-i --all-namespaces create clusterroles
```

Expected results:

- Application deployment creation: `yes` if the Role grants it.
- Application deployment reading: `yes` if the Role grants it.
- Secret creation: `no` if the Role does not grant it.
- ClusterRole creation: `no` for a namespace-scoped developer.

### Step 7: Perform a deployment task

```sh
kubectl apply -f deployment.yaml
kubectl rollout status deployment/my-application -n my-application
kubectl get pods -n my-application
kubectl describe pod <pod-name> -n my-application
```

The developer's AWS credentials are used to authenticate to EKS. The Kubernetes RBAC rules then authorize the requested manager operation.

---

## 9. What happens when a developer has no AWS credentials

A developer without valid AWS credentials cannot normally establish an EKS identity through the normal EKS token mechanism.

For example:

```sh
kubectl get nodes
```

will fail if the kubeconfig's exec authentication has no usable AWS credential or if the caller is not authorized through EKS.

A disconnected or anonymous Kubernetes identity cannot be accepted by the normal EKS API server. A Kubernetes API server can theoretically use another authentication provider, such as OIDC, certificates, or a static bearer token, but those are separate systems and should not be used as a shortcut for EKS in this setup.

The key point is:

```text
AWS credential or other trusted identity
        ->
EKS authentication
        ->
Kubernetes username/group
        ->
RBAC authorization
```

---

## 10. On-prem Kubernetes comparison

The same RBAC concepts work on an on-prem Kubernetes cluster, but the authentication mechanism is different.

### 10.1 On-prem request flow

```text
Developer certificate, token, OIDC identity, LDAP identity, or service account
        ->
Kubernetes API server authentication
        ->
Kubernetes username/group
        ->
RoleBinding or ClusterRoleBinding
        ->
Kubernetes API authorization
```

An on-prem cluster may authenticate users through:

- Client certificates.
- Bearer tokens.
- OIDC or OAuth providers.
- LDAP or Active Directory authentication.
- External authentication proxies.
- Kubernetes service accounts for automation.

The RBAC process is the same:

1. The API server verifies the user's identity.
2. The API server maps the identity to a Kubernetes username or group.
3. RoleBindings and ClusterRoleBindings are evaluated.
4. The API server accepts or rejects the operation.

### 10.2 On-prem kubeconfig

An on-prem kubeconfig typically contains:

```yaml
clusters:
  - name: on-prem
    cluster:
      server: https://kubernetes.example.com:6443
      certificate-authority-data: <base64-encoded-CA-certificate>
contexts:
  - name: developer
    context:
      cluster: on-prem
      user: developer-alice
current-context: developer
users:
  - name: developer-alice
    user:
      token: <short-lived-or-long-lived-token>
```

The token is a bearer credential. It must be protected and should be rotated or replaced automatically where possible.

For enterprise authentication, the kubeconfig may use an exec plugin or OIDC token provider:

```yaml
users:
  - name: developer-alice
    user:
      exec:
        apiVersion: client.authentication.k8s.io/v1beta1
        command: /path/to/authentication-plugin
```

The plugin returns the authentication token. The Kubernetes API server validates the token and determines the identity.

### 10.3 On-prem RBAC example

The same RoleBinding can be used with an on-prem cluster:

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
  - kind: User
    name: alice
```

The difference is that `alice` is authenticated through the on-prem authentication provider, not through an AWS IAM role or EKS access entry.

### 10.4 On-prem system comparison

| Concern | EKS | On-prem Kubernetes |
|---|---|---|
| Cluster endpoint | EKS API endpoint | Kubernetes API endpoint |
| Identity provider | AWS IAM, AWS SSO, or identity integration | OIDC, LDAP, certificate, token, or external provider |
| Token generation | EKS token or access entry | Authentication provider or service account token |
| Kubernetes identity | AWS principal mapped to username/group | Authenticated user mapped to username/group |
| RBAC | Role/RoleBinding or ClusterRole/ClusterRoleBinding | Role/RoleBinding or ClusterRole/ClusterRoleBinding |
| Workload identity | EKS Pod Identity or IRSA | Workload identity integration or service account token |
| Network access | EKS private/public endpoint | Private or public API endpoint controlled by the cluster platform |

---

## 11. Recommended access model for this repository

A safe production-ready model is:

1. Create a dedicated AWS IAM role for each developer or team.
2. Create EKS access entries for those roles.
3. Map the AWS principal to a dedicated Kubernetes group or username.
4. Create a namespace for the application.
5. Create a narrowly scoped Role with only required permissions.
6. Bind the dedicated developer group to that Role.
7. Create a separate service account for the application.
8. Associate the application workload with scoped AWS permissions.
9. Verify the identity with `kubectl auth whoami`.
10. Verify permissions with `kubectl auth can-i`.
11. Review the effective permissions and remove unused rules.
12. Protect the AWS credential and Kubernetes token.

The existing `system:masters` → `cluster-admin` access should not be used for normal developers. If it must be removed, first create a tested administrative replacement and preserve a recovery path.

---

## 12. Security checklist

- [ ] The developer identity is unique and associated with a named person or team.
- [ ] The AWS IAM role does not use the root account.
- [ ] The EKS access entry maps the principal to a dedicated Kubernetes group or username.
- [ ] The Kubernetes identity is not the broad `system:masters` group.
- [ ] Role permissions are limited to one namespace.
- [ ] The Role contains only required resources and verbs.
- [ ] The developer cannot create cluster roles or cluster role bindings.
- [ ] The developer cannot access unrelated namespaces.
- [ ] The application has a dedicated service account.
- [ ] The application workload has only the required AWS permissions.
- [ ] AWS credentials and Kubernetes tokens are protected.
- [ ] `kubectl auth whoami` is tested after every configuration change.
- [ ] `kubectl auth can-i` is run before allowing deployment operations.
- [ ] Access is reviewed regularly.
- [ ] A backup administrator identity is available before removing administrative access.
