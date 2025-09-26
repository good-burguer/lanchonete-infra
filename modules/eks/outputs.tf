output "cluster_name" {
  value = aws_eks_cluster.main.name
}

output "cluster_oidc_issuer_url" {
  value = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

output "oidc_provider_arn" {
  # Este recurso precisa ser criado dentro do módulo EKS também
  value = aws_iam_openid_connect_provider.eks.arn 
}

