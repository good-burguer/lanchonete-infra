variable "project_name" { type = string }
variable "environment" { type = string }
variable "cluster_name" { type = string }
variable "cluster_version" { type = string }
variable "vpc_id" { type = string }
variable "private_subnet_ids" { type = list(string) }
variable "instance_types" { type = list(string) }
# Adicione outras variáveis como desired_size, min_size, max_size