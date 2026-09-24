output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.this.id
}

output "public_subnet_ids" {
  description = "IDs of the public subnets by availability zone."
  value       = { for availability_zone, subnet in aws_subnet.public : availability_zone => subnet.id }
}

output "private_subnet_ids" {
  description = "IDs of the private subnets by availability zone."
  value       = { for availability_zone, subnet in aws_subnet.private : availability_zone => subnet.id }
}

output "nat_gateway_ids" {
  description = "IDs of the NAT gateways by availability zone."
  value       = { for availability_zone, nat_gateway in aws_nat_gateway.this : availability_zone => nat_gateway.id }
}
