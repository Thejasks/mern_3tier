#!/usr/bin/env bash
# Part 3 — Istio via Helm (no istioctl, no ~90 MB release tarball).
# Charts: base (CRDs) + istiod (control plane) in istio-system,
#         gateway (ingress gateway behind an AWS NLB) in istio-ingress.
# The gateway's proxy is injected by istiod, so it lives in its OWN injection-enabled
# namespace — istio-system has injection disabled (it's the control plane).
set -euo pipefail
VER="${ISTIO_VERSION:-1.24.0}"

helm repo add istio https://istio-release.storage.googleapis.com/charts >/dev/null 2>&1 || true
helm repo update istio >/dev/null

# control plane
kubectl create namespace istio-system --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install istio-base istio/base  -n istio-system --version "$VER"
helm upgrade --install istiod     istio/istiod -n istio-system --version "$VER" --wait

# ingress gateway — own namespace, injection on so istiod fills in the proxy container
kubectl create namespace istio-ingress --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace istio-ingress istio-injection=enabled --overwrite
helm upgrade --install istio-ingressgateway istio/gateway -n istio-ingress --version "$VER" -f - <<'YAML'
# label the pods so the Istio Gateway selector (istio: ingressgateway) binds them
labels:
  istio: ingressgateway
service:
  type: LoadBalancer
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: external
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: instance
    service.beta.kubernetes.io/aws-load-balancer-scheme: internet-facing
    service.beta.kubernetes.io/aws-load-balancer-subnets: subnet-018af919fe10d3b48,subnet-0ec0dcf3e46cd546d,subnet-052ea903c0f212f8e
YAML

kubectl -n istio-system  rollout status deploy/istiod
kubectl -n istio-ingress rollout status deploy/istio-ingressgateway
kubectl get svc -n istio-ingress istio-ingressgateway
