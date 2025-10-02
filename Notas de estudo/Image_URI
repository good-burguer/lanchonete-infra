Boa — vamos separar o que acontece hoje e o que não acontece:

O que o resume.sh faz hoje
	•	(Re)aplica a infra com Terraform.
	•	Aplica os manifests do Kubernetes (k8s/app: Deployment, Service, ServiceAccount etc.).
	•	Não troca a imagem do Deployment. Ou seja, o pod volta com a mesma imagem que já estava configurada (ou com a imagem “placeholder” do deployment.yaml, se for a primeira vez).

O que não acontece ao rodar o resume.sh
	•	Ele não dispara a pipeline do repositório lanchonete-app.
GitHub Actions só roda quando há push/PR/dispatch naquele repo, não quando você aplica infra localmente.

⸻

Quer atualizar a imagem ao final do resume.sh?

Você tem 3 caminhos. Escolha um:

1) (Simples/manual) Rodar o set image após o resume.sh

Se você sabe qual tag quer usar (ex.: a tag que a pipeline publicou), faça:

# exemplo: usar a última tag gerada pela pipeline
IMAGE_URI="822619186337.dkr.ecr.us-east-1.amazonaws.com/lanchonete-app:<sua-tag>"

kubectl -n app set image deploy/lanchonete-app app="$IMAGE_URI"
kubectl -n app rollout status deploy/lanchonete-app --timeout=180s
kubectl -n app get deploy lanchonete-app -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'

Dica para pegar a última imagem do ECR:

aws ecr describe-images --repository-name lanchonete-app \
  --query 'sort_by(imageDetails,& imagePushedAt)[-1].imageTags[-1]' --output text



2) (Opcional) Adicionar um bloco no resume.sh para usar IMAGE_URI se existir

Inclua isto no final do resume.sh (depois dos kubectl apply):

if [ -n "${IMAGE_URI:-}" ]; then
  echo "[resume] Atualizando Deployment com IMAGE_URI=${IMAGE_URI}"
  kubectl -n app set image deploy/lanchonete-app app="${IMAGE_URI}"
  kubectl -n app rollout status deploy/lanchonete-app --timeout=180s
else
  echo "[resume] IMAGE_URI não definida; mantendo a imagem atual."
fi

Aí, quando quiser já sair com a imagem nova, rode:

export IMAGE_URI="8226...amazonaws.com/lanchonete-app:<sua-tag>"
./resume.sh

3) (CI/CD) Disparar a pipeline do repo lanchonete-app
	•	Faça um commit no repo lanchonete-app (branch main) ou clique em “Re-run all jobs” no último workflow bem-sucedido.
	•	A pipeline de app já faz: build → push → kubectl set image.
Assim, ela trocará a imagem no cluster sem você mexer no resume.sh.

⸻

Resumo prático
	•	resume.sh não dispara o CD do app.
	•	Sem ajustes, ele não muda a imagem.
	•	Para atualizar a imagem após um resume.sh, ou:
	1.	faça o kubectl set image manualmente, ou
	2.	exporte IMAGE_URI e use o bloco opcional no script, ou
	3.	dispare a pipeline do lanchonete-app (o caminho “mais TC” porque automatiza build/push/deploy).