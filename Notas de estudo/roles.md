A. Roles de runtime (EKS cluster, nodes, pods):

No arquivo main.tf do lanchonete-infra você já tem três roles criadas via Terraform:
	1.	aws_iam_role.eks_cluster
→ usada pelo EKS Cluster para operar o control plane.
Policies anexadas:
	•	AmazonEKSClusterPolicy
	•	AmazonEKSVPCResourceController
	2.	aws_iam_role.eks_node
→ usada pelos Node Groups (EC2 workers) para rodar os pods.
Policies anexadas:
	•	AmazonEKSWorkerNodePolicy
	•	AmazonEC2ContainerRegistryReadOnly
	•	AmazonEKS_CNI_Policy
	3.	aws_iam_role.app_irsa
→ associada via IRSA (IAM Roles for Service Accounts) ao ServiceAccount app/lanchonete-app-sa.
Policies anexadas:
	•	Policy custom gb-dev-app-read-rds-secret, que permite apenas secretsmanager:GetSecretValue no secret do RDS.

⸻

👉 B. Roles para CI/CD pipelines via GitHub Actions.
	•	
