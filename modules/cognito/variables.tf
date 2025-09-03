variable "project_name" {
  description = "O nome do projeto (ex: lanchonete)."
  type        = string
}

variable "environment" {
  description = "O ambiente (ex: dev, prod)."
  type        = string
}

variable "tags" {
  description = "Tags para aplicar nos recursos."
  type        = map(string)
  default     = {}
}