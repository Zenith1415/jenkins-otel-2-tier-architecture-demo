#!/bin/bash
set -e

echo "  OTel obbservibility local setup for Jenkins "

echo ""
echo " Creating cluster"
if kind get clusters 2>/dev/null | grep -q otel-jenkins-poc; then
  echo "  Cluster exists, deleting..."
  kind delete cluster --name otel-jenkins-poc
fi
kind create cluster --config cluster.yaml
kubectl cluster-info --context kind-otel-jenkins-poc

echo ""
echo " Creating namespaces"
kubectl apply -f k8s/base/namespaces.yaml

echo ""
echo "Deploying backends"
kubectl apply -f k8s/backends/backends.yaml
kubectl wait --for=condition=available deployment/jaeger -n monitoring --timeout=120s
kubectl wait --for=condition=available deployment/prometheus -n monitoring --timeout=120s

echo ""
echo " Deploying OTel Collectors"
kubectl apply -f k8s/tier-2/configmap.yaml
kubectl apply -f k8s/tier-2/deployment.yaml
kubectl wait --for=condition=available deployment/otel-gateway -n observability --timeout=120s
kubectl apply -f k8s/tier-1/configmap.yaml
kubectl apply -f k8s/tier-1/daemonset.yaml
sleep 10

echo ""
echo "Deploying Jenkins"
kubectl apply -f k8s/jenkins/jenkins.yaml
kubectl wait --for=condition=available deployment/jenkins -n jenkins --timeout=180s

echo ""
echo "  Completed Access:"
echo "  Jenkins:    http://localhost:8080 (admin/admin)"
echo "  Jaeger:     http://localhost:16686"
echo "  Prometheus: http://localhost:9090"
