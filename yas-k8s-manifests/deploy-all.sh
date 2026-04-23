#!/bin/bash
echo "🚀 Deploying YAS to K8s..."
kubectl create namespace yas-dev 2>/dev/null || true
kubectl apply -f ~/yas-k8s-manifests/infra/postgres.yaml
echo "Waiting for PostgreSQL..."
kubectl wait --for=condition=ready pod -l app=postgres -n yas-dev --timeout=120s
kubectl apply -f ~/yas-k8s-manifests/infra/redis.yaml
kubectl apply -f ~/yas-k8s-manifests/infra/kafka.yaml
kubectl apply -f ~/yas-k8s-manifests/infra/keycloak.yaml
echo "✅ Infra deployed"
kubectl apply -f ~/yas-k8s-manifests/services/backend-services.yaml
kubectl apply -f ~/yas-k8s-manifests/services/nginx.yaml
echo "✅ Services deployed"
echo ""
kubectl get pods -n yas-dev
