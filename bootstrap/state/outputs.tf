output "bucket"     { value = aws_s3_bucket.tf_state.bucket }
output "lock_table" { value = aws_dynamodb_table.tf_lock.name }

output "vpc_id" {
  value = aws_vpc.gb.id
}

output "private_subnet_ids" {
  value = [for s in aws_subnet.private : s.id]
}

output "public_subnet_ids" {
  value = [for s in aws_subnet.public : s.id]
}