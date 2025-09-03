output "repository_urls" {
  description = "Mapa dos nomes dos repositórios para suas URLs."
  value = { for repo in aws_ecr_repository.main : repo.name => repo.repository_url }
}