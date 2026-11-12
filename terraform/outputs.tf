output "cluster_name" {
  description = "EKS cluster name."
  value       = module.eks.cluster_name
}

output "region" {
  description = "AWS region."
  value       = var.region
}

output "configure_kubectl" {
  description = "Command to point kubectl at the cluster."
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}

output "karpenter_node_role_name" {
  description = "IAM role name for Karpenter-launched nodes, referenced by the EC2NodeClass."
  value       = module.karpenter.node_iam_role_name
}

output "logs_bucket" {
  description = "S3 bucket that receives container logs from Fluent Bit."
  value       = aws_s3_bucket.logs.bucket
}
