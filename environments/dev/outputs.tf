output "region" { value = var.aws_region }
output "vpc_id" {
  value = aws_vpc.gb.id
}

output "private_subnet_ids" {
  value = [for s in aws_subnet.private : s.id]
}

output "public_subnet_ids" {
  value = [for s in aws_subnet.public : s.id]
}