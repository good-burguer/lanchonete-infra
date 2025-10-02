output "region" { value = var.aws_region }
output "eks_cluster_role_arn" { value = aws_iam_role.eks_cluster.arn }
output "eks_node_role_arn" { value = aws_iam_role.eks_node.arn }
output "eks_cluster_name" { value = aws_eks_cluster.this.name }
output "eks_cluster_endpoint" { value = aws_eks_cluster.this.endpoint }
output "eks_oidc_issuer" { value = aws_eks_cluster.this.identity[0].oidc[0].issuer }
output "eks_node_group_name" { value = aws_eks_node_group.default.node_group_name }
output "app_irsa_role_arn" { value = aws_iam_role.app_irsa.arn }
# IDs da VPC e das subnets privadas para outros módulos (ex.: database)
output "vpc_id" { value = aws_vpc.gb.id }
output "private_subnet_ids" { value = [for s in aws_subnet.private : s.id] }
output "eks_cluster_security_group_id" {
  value = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}
output "cognito_user_pool_id" {
  description = "ID do User Pool do Cognito."
  value       = aws_cognito_user_pool.user_pool.id
}

output "cognito_user_pool_client_id" {
  description = "ID do App Client do Cognito para o frontend."
  value       = aws_cognito_user_pool_client.app_client.id
}

output "api_gateway_invoke_url" {
  description = "URL base para invocar a API Gateway."
  value       = aws_api_gateway_stage.dev.invoke_url
}

output "lambda_artifacts_bucket_name" {
  description = "Nome do S3 bucket para armazenar os pacotes de deploy das Lambdas."
  value       = aws_s3_bucket.lambda_artifacts.bucket
}