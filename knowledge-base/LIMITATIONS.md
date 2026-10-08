# Development Environment Limitations

These limitations describe the current development EKS configuration. They are about `dev-eks` and `dev-eks-vpc` only.

## Public Kubernetes API

The Kubernetes API has public access enabled and no source-IP allowlist. In plain language, the login door can be reached from any internet connection, even though a caller still needs valid AWS/Kubernetes access to get in. For shared development use, restrict the endpoint to a trusted VPN or administrator IP range. This is especially important if several people or automated systems use the cluster.

## Team and deployment access

The Terraform does not declare EKS access entries or Kubernetes RBAC for a development team or deployment pipeline. The identity that creates the cluster may be able to administer it, but other users and automation need explicit access. Add separate roles with only the permissions each team or pipeline needs.

## Application exposure

The VPC subnets have public and internal load-balancer discovery tags, but this Terraform does not install an AWS Load Balancer Controller or configure ingress, DNS, or TLS. A pod can run without these, but testers may not have a URL to reach it. Add the controller and a secure ingress path when external access to a development application is needed.

## Persistent data

The EBS CSI driver and its IAM identity are not configured. Stateless development apps can run, but a pod requesting EBS-backed persistent storage may remain unable to obtain a volume. Add the CSI add-on and a dedicated Pod Identity or IRSA role if development databases or other stateful apps need EBS.

## Workload permissions

No per-application AWS identity is configured. The worker machines have baseline permissions, but an app that needs S3, Secrets Manager, or another AWS API should receive its own least-privilege role through EKS Pod Identity or IRSA. This avoids giving every app the same broad machine identity.

## Scaling and capacity

The development node group starts with 2 `t3.medium` instances and allows a maximum of 4. The configured maximum is only a ceiling; no node autoscaler is configured to add machines when pods cannot fit. If development tests need variable capacity, install a node autoscaler and, if needed, pod autoscaling plus metrics. Confirm subnet IP capacity too, because pods consume VPC addresses.

## Operations and recovery

Control-plane log types, dashboards, alerts, persistent-data backups, and an application delivery pipeline are not explicitly configured here. That is acceptable for a disposable experiment only if failures and lost data are understood. Add logging, alerts, repeatable deployments, and backups when the development environment is shared or holds valuable data.



Likely limitations

- Who can administer the cluster: You may be able to connect as the identity that creates the cluster, but this code doesn’t set up access for your team or deployment pipeline. Verify kubectl access after creation.
- Public API access: The Kubernetes API endpoint is reachable from any internet address. Authentication is still required, but for a shared environment you should limit which addresses can connect.
- Public app access: The subnet tags help AWS find load-balancer subnets, but they don’t install a load-balancer controller. If people outside the cluster need to visit your app, you’ll need to configure a way to expose it, plus DNS and TLS if appropriate.
- Persistent storage: An app that needs disks for data, such as a database, needs the EBS CSI driver and its permissions. Those aren’t configured here. A stateless app usually doesn’t need them.
- AWS permissions for apps: The worker machines have basic AWS permissions, but individual apps aren’t assigned their own AWS identities. An app needing S3 or another AWS service will need a dedicated setup such as EKS Pod Identity or IRSA.
- Scaling and visibility: Two t3.medium nodes are configured initially, with a maximum of four, but no autoscaler, logging, or alerts are configured here. If the nodes run out of space, new apps may stay waiting instead of starting.