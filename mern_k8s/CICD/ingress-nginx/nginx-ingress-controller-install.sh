#!/usr/bin/env bash
# Part 1 — NGINX Ingress controller, fronted by an AWS NLB (type LoadBalancer).
# (Requires the AWS Load Balancer Controller — prerequisites/aws-load-balancer-controller.sh)
set -euo pipefail
helm upgrade --install ingress-nginx oci://ghcr.io/nginxinc/charts/nginx-ingress --version 1.0.0 \
  -n ingress-nginx --create-namespace -f - <<'YAML'
controller:
  kind: deployment
  replicaCount: 2
  service:
    type: LoadBalancer
    externalTrafficPolicy: Cluster
    annotations:
      service.beta.kubernetes.io/aws-load-balancer-type: external
      service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: instance
      service.beta.kubernetes.io/aws-load-balancer-scheme: internet-facing
      service.beta.kubernetes.io/aws-load-balancer-subnets: subnet-018af919fe10d3b48,subnet-0ec0dcf3e46cd546d,subnet-052ea903c0f212f8e
rbac:
  create: true
YAML
kubectl -n ingress-nginx rollout status deploy/ingress-nginx-nginx-ingress-controller
echo "NLB DNS (point Route53 app/api at this):"
kubectl get svc ingress-nginx-nginx-ingress-controller -n ingress-nginx \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{"\n"}'

# No-LB fallback (if the account can't create LBs): use hostNetwork on :80 instead —
#   --set controller.kind=daemonset --set controller.hostNetwork=true
