#!/bin/bash

echo "Verificando status do Minikube..."
minikube status

echo ""
echo "Listando pods ativos no cluster:"
kubectl get pods

echo ""
echo "Mostrando contexto atual do kubectl:"
kubectl config current-context

echo ""
echo "IP do Minikube:"
minikube ip