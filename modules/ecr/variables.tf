variable "project_name" {
  type        = string
  description = "Nome do projeto para prefixar os recursos."
}

variable "environment" {
  type        = string
  description = "Ambiente (dev, prod)."
}

variable "repository_names" {
  type        = list(string)
  description = "Uma lista com os nomes dos repositórios a serem criados (ex: [\"api\", \"worker\"])."
  default     = []
}

variable "tags" {
  description = "Tags para aplicar nos recursos."
  type        = map(string)
  default     = {}
}