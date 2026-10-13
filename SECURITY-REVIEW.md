# EKS Security Review

**Review date:** 2026-10-13  
**Scope:** Repository configuration and documentation, including the EKS Terraform module and identity/RBAC guidance. This was a source review; it did not inspect the live cluster or run vulnerability scanners.

## Findings

| # | Severity | File | Lines | Finding | Confidence |
|---|----------|------|-------|---------|------------|
| 1 | HIGH | [knowledge-base/AUTHENTICATION-RBAC-GUIDE.md](knowledge-base/AUTHENTICATION-RBAC-GUIDE.md#L15) | 15-22, 106-131 | The development IAM identity `arn:aws:iam::378653386746:user/chuks` is documented as mapped to `system:masters`, granting cluster-admin privileges. A compromised or misused identity can administer the cluster and access workload data and Kubernetes secrets. | 8/10 |
| 2 | LOW | [modules/eks/main.tf](modules/eks/main.tf#L72) | 72-76 | The EKS public API endpoint is enabled without a `public_access_cidrs` allowlist, making the endpoint reachable from any source IP. EKS authentication remains required; this is an exposure-reduction hardening gap, not an authentication bypass. | 10/10 |

## Recommended actions

1. Replace the development identity's `system:masters` membership with a dedicated least-privilege Kubernetes Role and RoleBinding, scoped to the developer's namespace and tasks. Reserve cluster-admin for a separate, tightly controlled administrator identity. Manage access declaratively and validate the replacement access before removing the current mapping.
2. Restrict public API access to trusted VPN, office, and CI egress CIDRs using `public_access_cidrs`, or disable the public endpoint and use private connectivity. Keep any required operational access paths in mind before applying the change.
3. As operational follow-up, verify the live cluster's effective access mappings and API endpoint settings against the repository, since this review did not query the running cluster.
