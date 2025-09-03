resource "aws_ecr_repository" "main" {
  for_each = toset(var.repository_names)

  name = "${var.project_name}-${each.key}-${var.environment}"

  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = var.tags
}

resource "aws_ecr_lifecycle_policy" "main" {
  for_each   = aws_ecr_repository.main
  repository = each.key

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1,
        description  = "Expire images older than 14 days",
        selection = {
          tagStatus   = "untagged",
          countType   = "sinceImagePushed",
          countUnit   = "days",
          countNumber = 14
        },
        action = {
          type = "expire"
        }
      },
      {
        rulePriority = 2,
        description  = "Keep last 20 tagged images",
        selection = {
          tagStatus   = "tagged",
          tagPrefixList = ["v"], # Aplica-se a tags que começam com "v", ex: v1.0.0
          countType   = "imageCountMoreThan",
          countNumber = 20
        },
        action = {
          type = "expire"
        }
      }
    ]
  })
}