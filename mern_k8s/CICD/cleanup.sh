#!/usr/bin/env bash
# Full teardown: app + 3 controllers (their NLBs go with the Services) + Route53 records.
# Keeps Kyverno, ArgoCD, the EBS CSI driver and the LB controller.
#
# Designed to NEVER hang or exit non-zero: every step tolerates "already gone", blocking
# kubectl calls are wrapped in `timeout`, and namespaces are deleted with --wait=false.
# Safe to re-run any time.
set -uo pipefail   # deliberately no -e: teardown tolerates errors everywhere

ZONE="${ZONE:-Z07010022C4LQ7Z9ZKUKL}"   # Route53 hosted zone for hobbyez.com
NLBZONE="${NLBZONE:-ZVDDRBQ08TROA}"      # NLB canonical zone (ap-south-1)
APP_NS=(database backend frontend)
CTRL_NS=(ingress-nginx envoy-gateway-system istio-ingress istio-system)

echo "== uninstall routing controllers (this deletes their NLBs) =="
helm uninstall ingress-nginx        -n ingress-nginx        2>/dev/null || true
helm uninstall eg                   -n envoy-gateway-system 2>/dev/null || true
helm uninstall istio-ingressgateway -n istio-ingress        2>/dev/null || true
helm uninstall istiod               -n istio-system         2>/dev/null || true
helm uninstall istio-base           -n istio-system         2>/dev/null || true

echo "== delete leftover LoadBalancer Services (lets the LB controller reap NLBs) =="
# Deleting the Service triggers aws-load-balancer-controller to delete the NLB + drop its
# finalizer. Bounded wait so a wedged finalizer can't hang the script.
for ns in "${CTRL_NS[@]}"; do
  kubectl get ns "$ns" >/dev/null 2>&1 || continue
  timeout 90 kubectl delete svc --all -n "$ns" --wait=true 2>/dev/null || true
done

echo "== drop dangling istio/envoy admission webhooks (so API writes don't stall) =="
kubectl delete validatingwebhookconfiguration,mutatingwebhookconfiguration \
  -l 'app.kubernetes.io/part-of in (istio, envoy-gateway)' --ignore-not-found 2>/dev/null || true
kubectl delete validatingwebhookconfiguration istiod-default-validator istio-validator-istio-system \
  --ignore-not-found 2>/dev/null || true

echo "== delete routing objects + app namespaces =="
kubectl delete gatewayclass eg --ignore-not-found 2>/dev/null || true
timeout 60 kubectl delete ns "${APP_NS[@]}" "${CTRL_NS[@]}" \
  --ignore-not-found --wait=false 2>/dev/null || true

echo "== unstick any namespace wedged on a leftover LB-service finalizer =="
# If the NLB is already gone in AWS but the controller never dropped the finalizer, the ns
# hangs in Terminating forever. Strip the finalizer ONLY when the NLB really is gone (no leak).
LIVE_NLBS=$(aws elbv2 describe-load-balancers --query 'LoadBalancers[].DNSName' --output text 2>/dev/null || echo "")
for ns in "${CTRL_NS[@]}"; do
  kubectl get ns "$ns" >/dev/null 2>&1 || continue
  while read -r svc dns; do
    [ -z "$svc" ] && continue
    if [ -n "$dns" ] && echo "$LIVE_NLBS" | grep -qF "$dns"; then
      echo "  ! $ns/$svc still has a live NLB ($dns) — leaving finalizer (check AWS)"
      continue
    fi
    echo "  unstick $ns/$svc (NLB gone)"
    kubectl patch "svc/$svc" -n "$ns" --type=merge -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
  done < <(kubectl get svc -n "$ns" \
            -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.loadBalancer.ingress[0].hostname}{"\n"}{end}' 2>/dev/null)
done

echo "== delete Route53 demo records =="
for H in app api gateway api-gateway istio api-istio; do
  NAME="${H}.hobbyez.com."
  REC=$(aws route53 list-resource-record-sets --hosted-zone-id "$ZONE" \
        --query "ResourceRecordSets[?Name=='$NAME' && Type=='A']" --output json 2>/dev/null) || continue
  [ "$REC" = "[]" ] && continue
  DNS=$(echo "$REC" | python3 -c "import sys,json;print(json.load(sys.stdin)[0]['AliasTarget']['DNSName'])" 2>/dev/null) || continue
  aws route53 change-resource-record-sets --hosted-zone-id "$ZONE" --change-batch \
    "{\"Changes\":[{\"Action\":\"DELETE\",\"ResourceRecordSet\":{\"Name\":\"$NAME\",\"Type\":\"A\",\"AliasTarget\":{\"HostedZoneId\":\"$NLBZONE\",\"DNSName\":\"$DNS\",\"EvaluateTargetHealth\":true}}}]}" \
    >/dev/null 2>&1 && echo "  deleted $NAME"
done

echo "done."
exit 0
