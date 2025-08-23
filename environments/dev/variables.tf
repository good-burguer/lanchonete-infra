# Backend/config comuns
variable "aws_region" {
  type = string
}

variable "tf_state_bucket" {
  type = string
}

variable "tf_lock_table" {
  type = string
}

# EKS
variable "eks_cluster_name" {
  type    = string
  default = "gb-dev-eks"
}

variable "eks_version" {
  type    = string
  default = "1.29"   # fixe major.minor; não fixe patch
}

variable "eks_min_size" {
  type    = number
  default = 1
}

variable "eks_max_size" {
  type    = number
  default = 2
}

variable "eks_desired_size" {
  type    = number
  default = 1
}

variable "eks_instance_types" {
  type    = list(string)
  default = ["t3.small"]
}