variable "aws_region" {
  description = "AWS region in which to create the VPC."
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "Optional AWS CLI profile. Leave null to use the default credential chain."
  type        = string
  default     = "chuks"
  nullable    = true
}

variable "name" {
  description = "Optional VPC name override. Defaults to <environment>-eks-vpc."
  type        = string
  default     = null
  nullable    = true
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "Availability zones for the public and private subnet pairs."
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]

  validation {
    condition     = length(var.availability_zones) >= 2
    error_message = "At least two availability zones are required."
  }
}

variable "tags" {
  description = "Additional tags applied to VPC resources."
  type        = map(string)
  default     = {}
}

variable "environment" {
  description = "Deployment environment used to derive resource names and tags."
  type        = string
  default     = "dev"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,39}$", var.environment))
    error_message = "Environment must start with a lowercase letter and contain only lowercase letters, numbers, or hyphens (up to 40 characters)."
  }
}

variable "cluster_name" {
  description = "Optional EKS cluster name override. Defaults to <environment>-eks."
  type        = string
  default     = null
  nullable    = true
}

variable "kubernetes_version" {
  description = "Kubernetes version for the EKS control plane."
  type        = string
  default     = "1.36"
}

variable "node_instance_types" {
  description = "EC2 instance types for the managed node group."
  type        = list(string)
  default     = ["t3.medium"]
}

variable "node_desired_size" {
  description = "Desired number of worker nodes."
  type        = number
  default     = 2
}

variable "node_min_size" {
  description = "Minimum number of worker nodes."
  type        = number
  default     = 2
}

variable "node_max_size" {
  description = "Maximum number of worker nodes."
  type        = number
  default     = 4
}
