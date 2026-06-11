#!/usr/bin/env bash
# Create Route53 alias A records pointing hostnames at an NLB.
# Usage:  CICD/route53-alias.sh app.hobbyez.com api.hobbyez.com -- <nlb-dns-name>
# Required inputs (env):
#   ZONE     Route53 hosted zone id for the domain (hobbyez.com = Z07010022C4LQ7Z9ZKUKL)
#   NLBZONE  the NLB's canonical hosted zone id for the region (ap-south-1 = ZVDDRBQ08TROA)
set -euo pipefail

ZONE="${ZONE:?set ZONE (Route53 hosted zone id), e.g. export ZONE=Z07010022C4LQ7Z9ZKUKL}"
NLBZONE="${NLBZONE:?set NLBZONE (NLB canonical zone id), e.g. export NLBZONE=ZVDDRBQ08TROA}"

HOSTS=(); NLB=""; mode=hosts
for a in "$@"; do
  if [ "$a" = "--" ]; then mode=nlb; continue; fi
  if [ "$mode" = hosts ]; then HOSTS+=("$a"); else NLB="$a"; fi
done
[ -n "$NLB" ] && [ "${#HOSTS[@]}" -gt 0 ] || { echo "usage: $0 host [host...] -- <nlb-dns>"; exit 1; }

CHANGES=""
for h in "${HOSTS[@]}"; do
  CHANGES+="{\"Action\":\"UPSERT\",\"ResourceRecordSet\":{\"Name\":\"$h\",\"Type\":\"A\",\"AliasTarget\":{\"HostedZoneId\":\"$NLBZONE\",\"DNSName\":\"$NLB\",\"EvaluateTargetHealth\":true}}},"
done
aws route53 change-resource-record-sets --hosted-zone-id $ZONE \
  --change-batch "{\"Changes\":[${CHANGES%,}]}" --query 'ChangeInfo.Status' --output text
echo "  ${HOSTS[*]} -> $NLB"
