variable "region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-2"
}

variable "cluster_name" {
  description = "Name of the EKS cluster. Also used as the prefix for related resources."
  type        = string
  default     = "eks-platform-ref"
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version."
  type        = string
  default     = "1.31"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.20.0.0/16"
}

variable "single_nat_gateway" {
  description = "Use one NAT gateway (cheaper, single-AZ egress) instead of one per AZ. Set false for production-style resilience."
  type        = bool
  default     = true
}

variable "api_allowed_cidrs" {
  description = "CIDRs allowed to reach the public EKS API endpoint. Restrict this to your own IP."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "system_instance_types" {
  description = "Instance types for the managed node group that runs cluster-critical add-ons."
  type        = list(string)
  default     = ["m6i.large"]
}

variable "karpenter_version" {
  description = "Karpenter Helm chart version."
  type        = string
  default     = "1.1.1"
}

variable "log_retention_days" {
  description = "Days to keep container logs in the S3 logs bucket."
  type        = number
  default     = 30
}
