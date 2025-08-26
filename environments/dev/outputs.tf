output "region" { value = var.aws_region }
output "eks_cluster_role_arn" { value = aws_iam_role.eks_cluster.arn }
output "eks_node_role_arn"    { value = aws_iam_role.eks_node.arn }
output "eks_cluster_name"     { value = aws_eks_cluster.this.name }
output "eks_cluster_endpoint" { value = aws_eks_cluster.this.endpoint }
output "eks_oidc_issuer"      { value = aws_eks_cluster.this.identity[0].oidc[0].issuer }
output "eks_node_group_name"  { value = aws_eks_node_group.default.node_group_name }
output "app_irsa_role_arn"    { value = aws_iam_role.app_irsa.arn}
# IDs da VPC e das subnets privadas para outros módulos (ex.: database)
output "vpc_id"               {value = aws_vpc.gb.id}
output "private_subnet_ids"   {value = [for s in aws_subnet.private : s.id]}
output "eks_cluster_security_group_id" {
  value = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}