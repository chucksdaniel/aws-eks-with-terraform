# EKS Security Review

**Review date:** 2026-10-13  
**Scope:** Repository configuration and documentation, including the EKS Terraform module and identity/RBAC guidance. This was a source review; it did not inspect the live cluster or run vulnerability scanners.

## Findings

| # | Severity | File | Lines | Finding | Confidence |
|---|----------|------|-------|---------|------------|
| 1 | HIGH | [knowledge-base/AUTHENTICATION-RBAC-GUIDE.md](knowledge-base/AUTHENTICATION-RBAC-GUIDE.md#L15) | 15-22, 106-131 | The development IAM identity `arn:aws:iam::378653386746:user/chuks` is documented as mapped to `system:masters`, granting cluster-admin privileges. A compromised or misused identity can administer the cluster and access workload data and Kubernetes secrets. | 8/10 |
| 2 | LOW | [modules/eks/main.tf](modules/eks/main.tf#L72) | 72-77 | The public API endpoint was initially enabled without a `public_access_cidrs` allowlist, making it reachable from any source IP. Terraform now defaults to `102.140.100.226/32` and supports adding additional trusted CIDRs. EKS authentication remains required; this was an exposure-reduction hardening gap, not an authentication bypass. | 10/10 |

## Recommended actions

1. Replace the development identity's `system:masters` membership with a dedicated least-privilege Kubernetes Role and RoleBinding, scoped to the developer's namespace and tasks. Reserve cluster-admin for a separate, tightly controlled administrator identity. Manage access declaratively and validate the replacement access before removing the current mapping.
2. **Terraform remediation implemented; deployment pending:** the public endpoint now defaults to `102.140.100.226/32`. Add any other administrators' stable egress ranges to `cluster_public_access_cidrs` in environment-specific Terraform inputs. Review the plan and confirm that all required access paths are included before applying; alternatively, disable public access and use private connectivity.
3. As operational follow-up, verify the live cluster's effective access mappings and API endpoint settings against the repository, since this review did not query the running cluster.
