#!/usr/bin/env bash
# Install Argo CD in the cluster and expose the dashboard via NodePort.
# Usage:  ./install/argocd-setup.sh
set -euo pipefail

# 1. Install Argo CD
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# wait for Argo CD to start (so the admin secret exists)
kubectl -n argocd rollout status deploy/argocd-server --timeout=300s

# 2. Expose the dashboard as a NodePort service
kubectl patch svc argocd-server -n argocd -p '{"spec": {"type": "NodePort"}}'

# 3. Login details
echo
echo "ArgoCD username: admin"
echo "ArgoCD password: $(kubectl get secrets -n argocd argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)"
echo "Dashboard port:  $(kubectl get svc argocd-server -n argocd -o jsonpath='{.spec.ports[?(@.port==443)].nodePort}')  (https://<node-ip>:<that-port>)"
