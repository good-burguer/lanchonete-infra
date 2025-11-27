# Lanchonete – Infra (Terraform)

Este repositório define e gerencia toda a infraestrutura em nuvem da aplicação Good Burger utilizando Terraform. Aqui são configurados e mantidos os recursos essenciais como EKS, VPC, ECR, IAM, S3, DynamoDB, entre outros, garantindo um ambiente seguro, escalável e automatizado para os serviços da aplicação.

## Descrição Geral

Esta camada de infraestrutura provê o ambiente base para o funcionamento dos serviços `lanchonete-app`, `lanchonete-auth` e `lanchonete-db`. Com a infraestrutura definida como código, é possível garantir consistência, versionamento e facilidade na replicação dos ambientes.

## Arquitetura

- **VPC**: Rede virtual privada configurada com subnets públicas e privadas, incluindo NAT Gateway para acesso seguro à internet e Internet Gateway para comunicação externa.
- **EKS Cluster**: Cluster Kubernetes gerenciado que orquestra os serviços de aplicação, garantindo alta disponibilidade e escalabilidade.
- **ECR**: Repositório de imagens Docker para armazenar e versionar as imagens utilizadas pelos serviços.
- **S3 + DynamoDB**: Armazenamento do estado remoto do Terraform, utilizando S3 para o bucket de estado e DynamoDB para o lock do estado, garantindo integridade e concorrência.
- **IAM Roles**: Papéis e políticas específicas para os pipelines de CI/CD e para os serviços, garantindo o princípio do menor privilégio.

## Estrutura

Toda a infraestrutura é definida diretamente no arquivo `main.tf`, que contém os recursos da VPC, EKS, ECR, IAM, S3 e DynamoDB.  
O arquivo `variables.tf` armazena as definições das variáveis utilizadas, enquanto os valores específicos de ambiente são configurados no `terraform.tfvars`.  
O estado remoto do Terraform é mantido em um bucket S3 com bloqueio de concorrência via DynamoDB, garantindo consistência e segurança na execução dos pipelines.  

## Comandos Terraform

Exemplos de comandos para gerenciar a infraestrutura:

```bash
terraform init
terraform plan
terraform apply
```

## CI/CD

O pipeline configurado no GitHub Actions executa automaticamente as validações do Terraform (`terraform validate` e `terraform plan`) em Pull Requests para garantir a qualidade das alterações. Após o merge na branch `main`, o pipeline realiza o `terraform apply` automaticamente, utilizando autenticação via OIDC para acesso seguro aos recursos AWS.

## Autores

Time *The Code Crafters*  
Projeto FIAP - Pós-Graduação em Tecnologia (SOAT)
