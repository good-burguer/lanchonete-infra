#!/bin/bash

# Verifica se está rodando no macOS
if [[ "$OSTYPE" == "darwin"* ]]; then
  # Verifica se o Homebrew está instalado
  if ! command -v brew >/dev/null 2>&1; then
    echo "Homebrew não está instalado. Instalando Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    export PATH="/opt/homebrew/bin:$PATH"
  fi
fi

# Verifica se o Minikube está instalado, se não estiver, instala automaticamente
if ! command -v minikube >/dev/null 2>&1; then
  echo "Minikube não está instalado. Instalando automaticamente..."
  if [[ "$OSTYPE" == "darwin"* ]]; then
    brew install minikube
  elif [[ "$OSTYPE" == "linux"* ]]; then
    curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
    sudo install minikube-linux-amd64 /usr/local/bin/minikube
    rm minikube-linux-amd64
  else
    echo "Sistema operacional não suportado para instalação automática. Instale o Minikube manualmente: https://minikube.sigs.k8s.io/docs/start/"
    exit 1
  fi
fi

# Verifica se o Minikube está rodando
if ! minikube status | grep -q "host: Running"; then
  echo "Minikube não está rodando. Iniciando Minikube..."
  minikube start
fi

echo "Dica: Para usar imagens locais, execute antes:"
echo "eval \$(minikube docker-env)"

echo "Verificando se o metrics-server está instalado..."
if ! kubectl get deployment metrics-server -n kube-system >/dev/null 2>&1; then
  echo "Instalando metrics-server..."
  kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
  echo "Aguardando metrics-server iniciar..."
  kubectl wait --for=condition=available deployment/metrics-server -n kube-system --timeout=120s
else
  echo "metrics-server já está instalado."
fi

echo "Aplicando configuração --kubelet-insecure-tls no metrics-server..."
kubectl -n kube-system patch deployment metrics-server \
  --type='json' \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]' 2>/dev/null || \
kubectl -n kube-system patch deployment metrics-server \
  --type='json' \
  -p='[{"op":"replace","path":"/spec/template/spec/containers/0/args/6","value":"--kubelet-insecure-tls"}]' 2>/dev/null || \
echo "Parâmetro --kubelet-insecure-tls já presente ou não foi necessário alterar."

echo "Aplicando manifestos Kubernetes..."
kubectl apply -f k8s/

echo "Aguardando pods da aplicação subirem..."
kubectl wait --for=condition=ready pod -l app=lanchonete-app --timeout=120s

# Verifica se a porta 8080 está em uso e libera se necessário
PORT=8080
PID=$(lsof -ti tcp:$PORT)
if [ -n "$PID" ]; then
  echo "A porta $PORT está em uso pelo processo $PID. Matando o processo..."
  kill -9 $PID
  sleep 1
fi

echo "Fazendo port-forward para http://localhost:8080 ..."
kubectl port-forward service/lanchonete-app-service 8080:80 &
PORT_FORWARD_PID=$!

DB_PORT=5432
PID=$(lsof -ti tcp:$DB_PORT)
if [ -n "$PID" ]; then
  echo "A porta $DB_PORT está em uso pelo processo $PID. Matando o processo..."
  kill -9 $PID
  sleep 1
fi

echo "Fazendo port-forward para a porta 5432 ..."
kubectl port-forward service/db 5432:5432 &
PORT_FORWARD_PID=$!

echo "Aguardando 5 segundos para garantir que o serviço está disponível..."
sleep 5

echo "Testando endpoint principal com curl:"
curl -i http://localhost:8080/health

echo "Testando documentação Swagger:"
curl -I http://localhost:8080/docs

echo ""
echo "Acesse a documentação Swagger em: http://localhost:8080/docs"
echo "Para interromper o port-forward, use: kill $PORT_FORWARD_PID"