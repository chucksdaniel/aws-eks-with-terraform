output "cluster_name" {
  description = "Name of the EKS cluster."
  value       = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  description = "API endpoint of the EKS cluster."
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_security_group_id" {
  description = "Security group ID created for the EKS cluster."
  value       = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}
