#!/usr/bin/env bash
# Prerequisite — AWS Load Balancer Controller (so Service type=LoadBalancer -> NLB).
# Idempotent. Account 637423622313 / ap-south-1 values baked in.
set -euo pipefail
REGION=ap-south-1
VPC_ID=vpc-038609c3065e54a8c
CLUSTER_NAME=kubernetes
LBC_VERSION=v2.13.0
ACCOUNT=637423622313
SUBNETS="subnet-018af919fe10d3b48 subnet-0ec0dcf3e46cd546d subnet-052ea903c0f212f8e"
NODE_IDS="i-00dcb203162b07226 i-06870bb0c40396626 i-0595dd0c7e303add5 i-008c70080775e75a7 i-0cf9ce591f0737ac9"
POLICY_ARN="arn:aws:iam::${ACCOUNT}:policy/AWSLoadBalancerControllerIAMPolicy"

# 1. IAM policy + a node role that carries it (also ECR pull + EBS CSI)
curl -fsSL -o /tmp/lbc.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/${LBC_VERSION}/docs/install/iam_policy.json
aws iam create-policy --policy-name AWSLoadBalancerControllerIAMPolicy --policy-document file:///tmp/lbc.json >/dev/null 2>&1 || echo "policy exists"
cat > /tmp/ec2-trust.json <<'JSON'
{ "Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}
JSON
aws iam create-role --role-name k8s-node-role --assume-role-policy-document file:///tmp/ec2-trust.json >/dev/null 2>&1 || echo "role exists"
for P in "$POLICY_ARN" arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy; do
  aws iam attach-role-policy --role-name k8s-node-role --policy-arn "$P" 2>/dev/null || true
done
aws iam create-instance-profile --instance-profile-name k8s-node-profile >/dev/null 2>&1 || true
aws iam add-role-to-instance-profile --instance-profile-name k8s-node-profile --role-name k8s-node-role 2>/dev/null || true
sleep 8
for ID in $NODE_IDS; do
  aws ec2 associate-iam-instance-profile --region $REGION --instance-id "$ID" --iam-instance-profile Name=k8s-node-profile >/dev/null 2>&1 || true
done

# 2. NOTE: kubeadm has no cloud-provider, so each node needs spec.providerID set to
#    aws:///<az>/<instance-id> for instance-mode NLB targets. Already set on this
#    cluster. For a fresh node:
#      kubectl patch node <name> -p '{"spec":{"providerID":"aws:///ap-south-1a/<instance-id>"}}'

# 3. Tag subnets for ELB discovery
for S in $SUBNETS; do
  aws ec2 create-tags --region $REGION --resources $S --tags Key=kubernetes.io/role/elb,Value=1 "Key=kubernetes.io/cluster/${CLUSTER_NAME},Value=shared"
done

# 4. Install the controller
helm repo add eks https://aws.github.io/eks-charts >/dev/null 2>&1 || true
helm repo update >/dev/null
kubectl apply -k "github.com/aws/eks-charts/stable/aws-load-balancer-controller/crds?ref=master"
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller -n kube-system \
  --set clusterName=${CLUSTER_NAME} --set region=${REGION} --set vpcId=${VPC_ID} \
  --set serviceAccount.create=true --set serviceAccount.name=aws-load-balancer-controller
kubectl -n kube-system rollout status deploy/aws-load-balancer-controller
