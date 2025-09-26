variable "project_name" {
  description = "O nome do projeto (ex: lanchonete)."
  type        = string
}

variable "environment" {
  description = "O ambiente (ex: dev, prod)."
  type        = string
}

# --- Entradas da Rede ---
variable "vpc_id" {
  description = "ID da VPC onde o ALB do EKS está."
  type        = string
}

variable "private_subnet_ids" {
  description = "Lista de IDs das sub-redes privadas para o VPC Link."
  type        = list(string)
}

# --- Entradas do Backend (EKS/ALB) ---
variable "target_alb_listener_arn" {
  description = "ARN do Listener do Application Load Balancer que serve a aplicação."
  type        = string
}

# --- Entradas de Segurança (Cognito) ---
variable "cognito_user_pool_endpoint" {
  description = "Endpoint do User Pool do Cognito (usado como 'issuer' JWT)."
  type        = string
}

variable "cognito_user_pool_client_id" {
  description = "ID do cliente do Cognito (usado como 'audience' JWT)."
  type        = string
}

variable "tags" {
  description = "Tags para aplicar nos recursos."
  type        = map(string)
  default     = {}
}