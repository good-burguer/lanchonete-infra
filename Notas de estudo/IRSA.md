# IRSA (IAM Roles for Service Accounts)

IRSA (IAM Roles for Service Accounts) é uma funcionalidade do Amazon EKS que permite associar roles do IAM diretamente a Service Accounts do Kubernetes. Isso possibilita que os pods assumam permissões específicas do IAM sem a necessidade de usar credenciais estáticas ou permissões amplas no nó.

## Benefícios do IRSA

- **Segurança aprimorada**: Permite controle granular de permissões por pod.
- **Menor superfície de ataque**: Evita o uso de credenciais estáticas.
- **Gerenciamento simplificado**: As permissões são gerenciadas diretamente via IAM e Kubernetes.

## Como funciona

1. Cria-se uma Role do IAM com uma trust policy que permite que a Service Account do Kubernetes assuma essa Role.
2. Anota-se a Service Account com o ARN da Role do IAM.
3. Quando o pod é iniciado, o kubelet injeta um token OIDC na Service Account.
4. O SDK da AWS dentro do pod usa esse token para obter credenciais temporárias da Role do IAM.

## Diagrama (ASCII)

```text
[Terraform]                                     [Kubernetes / EKS]
    |                                                |
    |-- Cria OIDC Provider do EKS -------------------|  (aws_iam_openid_connect_provider)
    |-- Cria IAM Role (gb-dev-eks-app-secrets)       |
    |     \-- Trust Policy:                          |
    |         - Principal: OIDC Provider do cluster  |
    |         - Action: sts:AssumeRoleWithWebIdentity|
    |         - Condition:                           |
    |             aud = sts.amazonaws.com            |
    |             sub = system:serviceaccount:app:lanchonete-app-sa
    |                                                |
    |----------------------------------------------->|
                                                   |
Dev aplica manifests (kubectl apply -f k8s/app/)     |
    |                                                |
    v                                                v
[ServiceAccount lanchonete-app-sa]  --(annotation: eks.amazonaws.com/role-arn=... )-->
[Pod do app]  --(kubelet monta token OIDC em /var/run/secrets/eks.amazonaws.com/serviceaccount/token)-->
[SDK AWS no container] --(AssumeRoleWithWebIdentity)--> [AWS STS]
    |                                                                  |
    |<-------------------- Credenciais temporárias ---------------------|
    |
    +--> [Secrets Manager / RDS etc.]  (permissões da Role)
    |
    +--> [Aplicação] lê segredo e conecta no RDS
```

---

# OIDC (OpenID Connect)

OIDC é um protocolo de autenticação baseado em OAuth 2.0 que permite que um serviço confie na identidade de um usuário ou serviço através de um provedor de identidade.

## OIDC no contexto do EKS

O EKS cria um provedor OIDC associado ao cluster, que permite que as Service Accounts do Kubernetes possam autenticar-se no IAM usando tokens JWT.

### Como verificar o provedor OIDC do cluster

```bash
aws eks describe-cluster --name <cluster-name> --query "cluster.identity.oidc.issuer" --output text
```

---

# Kubelet e IRSA

O kubelet é o agente que roda em cada nó do Kubernetes e é responsável por iniciar e gerenciar os pods.

## Papel do Kubelet no IRSA

- O kubelet monta o token do Service Account dentro do pod.
- Esse token é um JWT emitido pelo provedor OIDC do cluster.
- O token é usado pelas aplicações dentro do pod para solicitar credenciais temporárias do IAM.

## Exemplo de montagem do token

O token é montado no caminho padrão `/var/run/secrets/eks.amazonaws.com/serviceaccount/token` dentro do pod.

---

# Exemplo de configuração de IRSA

1. **Criar a Role do IAM com trust policy para o OIDC provider**

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::<account-id>:oidc-provider/<oidc-provider>"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "<oidc-provider>:sub": "system:serviceaccount:<namespace>:<service-account-name>"
        }
      }
    }
  ]
}
```

2. **Anotar a Service Account**

```bash
kubectl annotate serviceaccount <service-account-name> -n <namespace> eks.amazonaws.com/role-arn=arn:aws:iam::<account-id>:role/<role-name>
```

3. **Usar a Service Account no pod**

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: example-pod
  namespace: <namespace>
spec:
  serviceAccountName: <service-account-name>
  containers:
  - name: app
    image: amazonlinux
    command: ["/bin/sh", "-c", "sleep 3600"]
```

Com essa configuração, o pod terá as permissões definidas na Role do IAM associada à Service Account, utilizando IRSA para autenticação segura e granular.

---

# Responsabilidades por Componente

- **Terraform**: cria a Role do IAM e define a trust policy que permite a autenticação via OIDC.  
- **AWS/EKS**: provisiona o cluster, associa o provedor OIDC ao IAM e valida os tokens emitidos.  
- **OIDC Provider**: emite os tokens JWT usados para autenticação das Service Accounts.  
- **Kubernetes**: cria e gerencia as Service Accounts, anota com o ARN da Role e monta o token no pod.  
- **Kubelet**: injeta o token OIDC da Service Account dentro do contêiner, permitindo que o SDK da AWS solicite credenciais temporárias.  


## Responsabilidades por Componente

**Terraform (IaC)**
- Cria/atualiza o **EKS** (cluster e node group), quando definido no Terraform.
- Cria o **OIDC Provider** do cluster (`aws_iam_openid_connect_provider`) apontando para o *issuer* do EKS.
- Cria a **IAM Role** `gb-dev-eks-app-secrets` com:
  - **Trust policy** permitindo `sts:AssumeRoleWithWebIdentity` via OIDC.
  - **Condições** típicas: `aud=sts.amazonaws.com` e `sub=system:serviceaccount:app:lanchonete-app-sa`.
  - **Policy** anexada (ex.: `secretsmanager:GetSecretValue`) conforme necessidade do pod.

**Kubernetes (manifests)**
- Cria o **Namespace** `app`.
- Cria a **ServiceAccount** `lanchonete-app-sa` com a anotação  
  `eks.amazonaws.com/role-arn: arn:aws:iam::<account-id>:role/gb-dev-eks-app-secrets`.
- Define o **Deployment** do app referenciando `serviceAccountName: lanchonete-app-sa`, imagem do ECR, probes e variáveis de ambiente.

**kubelet (em cada nó do EKS)**
- **Monta** no pod um volume projetado com o **token OIDC** da ServiceAccount:  
  `/var/run/secrets/eks.amazonaws.com/serviceaccount/token`.
- **Renova** o token quando necessário e mantém o volume atualizado.

**AWS STS**
- Recebe a chamada `AssumeRoleWithWebIdentity`, **valida** o token OIDC (issuer, assinatura e `sub/aud`).
- **Emite credenciais temporárias** (AccessKey/SecretKey/SessionToken) atreladas à Role.

**Aplicação (SDK AWS dentro do pod)**
- Usa automaticamente as **credenciais temporárias** para chamar serviços (p.ex. **Secrets Manager**) e obter segredos (host, user, senha).
- Com os segredos em mãos, **conecta-se ao RDS**.

**ECR**
- Armazena a **imagem do container** usada no Deployment.

**Resumo prático**
- *Terraform* cuida do que é **IAM/EKS/OIDC**.
- *Kubernetes* cuida do que é **ServiceAccount/Pods/Deployments**.
- *kubelet* faz a **ponte** montando o token no pod.
- *STS* troca token por **credenciais temporárias**.
- *Aplicação* usa as credenciais para **acessar AWS** (ex.: Secrets Manager) sem chave fixa.



	•	Terraform cria:
	•	O OIDC Provider (aws_iam_openid_connect_provider) que conecta o EKS ao IAM.
	•	A IAM Role (ex.: gb-dev-eks-app-secrets) com trust policy que permite pods assumirem a role via OIDC.
	•	Kubernetes cria:
	•	A ServiceAccount (lanchonete-app-sa) anotada com o ARN da role.
	•	O Deployment que usa essa ServiceAccount.
	•	kubelet (agente do nó) monta dentro do pod um token OIDC da ServiceAccount.
	•	AWS STS recebe esse token e devolve credenciais temporárias.
	•	Aplicação dentro do pod usa essas credenciais para acessar recursos da AWS (ex.: Secrets Manager, RDS), sem precisar de chaves fixas.

👉 Em resumo: o IRSA conecta ServiceAccount → IAM Role → STS → credenciais temporárias, garantindo acesso seguro aos serviços da AWS.

## Fluxo resumido (Item 4)

```text
[ServiceAccount]
       |
       v
   [IAM Role]
       |
       v
      [STS]
       |
       v
[Credenciais temporárias]
       |
       v
   [Aplicação]
```

