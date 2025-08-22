# Lanchonete – Infra (Terraform)
Infra do EKS/VPC/ECR via Terraform.

## Estrutura
- `modules/` módulos reutilizáveis
- `environments/dev` entrada do ambiente
- `.github/workflows/` pipelines

## Como validar
1. Defina VARS no repo: `AWS_REGION`, `TF_STATE_BUCKET`, `TF_LOCK_TABLE`
2. O CI rodará `terraform init/validate/plan` em PR e `apply` no merge.
