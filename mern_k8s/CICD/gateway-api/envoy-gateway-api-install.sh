#!/usr/bin/env bash
# Part 2 — Gateway API CRDs + Envoy Gateway controller.
set -euo pipefail
# Gateway API CRDs (only if missing — cluster may already have a newer set)
kubectl get crd httproutes.gateway.networking.k8s.io >/dev/null 2>&1 || \
  kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.0/standard-install.yaml
# Envoy Gateway (CRDs handled above -> skip the chart's bundled ones)
helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm --version v1.2.0 \
  -n envoy-gateway-system --create-namespace --skip-crds
kubectl -n envoy-gateway-system rollout status deploy/envoy-gateway
kubectl get gatewayclass
# GatewayClass + EnvoyProxy: point Gateways at Envoy Gateway, and front the proxy
# with an AWS NLB (type LoadBalancer + NLB annotations; instance target).
kubectl apply -f - <<'YAML'
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyProxy
metadata: { name: custom-proxy, namespace: envoy-gateway-system }
spec:
  provider:
    type: Kubernetes
    kubernetes:
      envoyService:
        type: LoadBalancer
        externalTrafficPolicy: Cluster
        annotations:
          service.beta.kubernetes.io/aws-load-balancer-type: external
          service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: instance
          service.beta.kubernetes.io/aws-load-balancer-scheme: internet-facing
          service.beta.kubernetes.io/aws-load-balancer-subnets: subnet-018af919fe10d3b48,subnet-0ec0dcf3e46cd546d,subnet-052ea903c0f212f8e
---
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata: { name: eg }
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
  parametersRef:
    group: gateway.envoyproxy.io
    kind: EnvoyProxy
    name: custom-proxy
    namespace: envoy-gateway-system
YAML
