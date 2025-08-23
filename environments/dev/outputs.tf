output "region" { value = var.aws_region }
output "eks_cluster_role_arn" { value = aws_iam_role.eks_cluster.arn }
output "eks_node_role_arn"    { value = aws_iam_role.eks_node.arn }
output "eks_cluster_name"     { value = aws_eks_cluster.this.name }
output "eks_cluster_endpoint" { value = aws_eks_cluster.this.endpoint }
output "eks_oidc_issuer"      { value = aws_eks_cluster.this.identity[0].oidc[0].issuer }
output "eks_node_group_name"  { value = aws_eks_node_group.default.node_group_name }