# MERN 3-tier on Kubernetes — deploy + north-south routing

Three tiers (MongoDB / Express / React), deployed to EKS-style kubeadm on EC2, then
exposed three ways for comparison: **nginx Ingress**, **Gateway API (Envoy)**, **Istio**.
Each controller sits behind its **own AWS NLB** (one controller, one LB — the real pattern).

> Source code: `backend`, `frontend`. The `CICD/` directory holds everything to deploy
> and route. **Run all commands from the repo root.** Account `637423622313`, region
> `ap-south-1`, domain `hobbyez.com` are baked into the scripts.

```
CICD/
├── prerequisites/        argocd-setup.sh · ecr-setup.sh · aws-load-balancer-controller.sh
├── kyverno-policies/     disallow-latest-tag.yaml
├── deploy/
│   ├── manifests/{database,backend,frontend}/   raw k8s (one ns each)
│   └── helm/{database,backend,frontend}/         same app, Helm
├── ingress-nginx/        nginx-ingress-controller-install.sh · ingress.yaml
├── gateway-api/          envoy-gateway-api-install.sh · gateway.yaml · httproute.yaml
└── istio/                istio-install.sh · gateway.yaml · virtualservice.yaml
```

---

## 1. Prerequisites

### 1.1 kubectl + AWS
```bash
kubectl config current-context          # must point at the cluster
aws sts get-caller-identity             # must return account 637423622313
export AWS_REGION=ap-south-1             # or: aws configure
```

### 1.2 Kyverno + policy (block :latest)
```bash
helm install kyverno kyverno --repo https://kyverno.github.io/kyverno/ -n kyverno --create-namespace
kubectl -n kyverno rollout status deploy/kyverno-admission-controller
kubectl apply -f CICD/kyverno-policies/disallow-latest-tag.yaml
```

### 1.3 EBS CSI driver (for Mongo's PVC)
```bash
helm repo add aws-ebs-csi-driver https://kubernetes-sigs.github.io/aws-ebs-csi-driver
helm repo update
helm upgrade --install aws-ebs-csi-driver aws-ebs-csi-driver/aws-ebs-csi-driver -n kube-system
# IAM: the node role needs AmazonEBSCSIDriverPolicy — attached by the LB-controller script (1.4).
```

### 1.4 AWS Load Balancer Controller (so Service type=LoadBalancer → NLB)
```bash
cd CICD && ./prerequisites/aws-load-balancer-controller.sh && cd ..
```
This also creates the node IAM role (ECR pull + EBS + ELB). *(`providerID` is already set on
these nodes — see the script's note for a fresh node.)*

---

## 2. Build & deploy frontend + backend

### 2.1 Create ECR repos + push images (linux/amd64 for the EC2 nodes)
```bash
ECR=637423622313.dkr.ecr.ap-south-1.amazonaws.com
aws ecr create-repository --region ap-south-1 --repository-name mern-backend  >/dev/null 2>&1 || true
aws ecr create-repository --region ap-south-1 --repository-name mern-frontend >/dev/null 2>&1 || true
aws ecr get-login-password --region ap-south-1 | docker login --username AWS --password-stdin $ECR

docker buildx build --platform linux/amd64 -t $ECR/mern-backend:1  --push backend
docker buildx build --platform linux/amd64 -t $ECR/mern-frontend:1 --push frontend
```

### 2.2 Deploy — Option A: raw manifests
```bash
ECR=637423622313.dkr.ecr.ap-south-1.amazonaws.com
# database (creates ns + ebs-mongo StorageClass + mongo)
kubectl apply -f CICD/deploy/manifests/database/

# backend + frontend each need the ECR pull secret in their namespace
for ns in backend frontend; do
  kubectl apply -f CICD/deploy/manifests/$ns/00-namespace.yaml
  kubectl create secret docker-registry ecr-creds -n $ns \
    --docker-server=$ECR --docker-username=AWS \
    --docker-password="$(aws ecr get-login-password --region ap-south-1)"
done
kubectl apply -f CICD/deploy/manifests/backend/
kubectl apply -f CICD/deploy/manifests/frontend/
```

### 2.2 Deploy — Option B: Helm (same app)
```bash

helm install database CICD/deploy/helm/database -n database --create-namespace

ECR=637423622313.dkr.ecr.ap-south-1.amazonaws.com
kubectl create namespace backend
kubectl create secret docker-registry ecr-creds -n backend --docker-server=$ECR --docker-username=AWS \
  --docker-password="$(aws ecr get-login-password --region ap-south-1)"
helm install backend CICD/deploy/helm/backend -n backend

helm install frontend CICD/deploy/helm/frontend -n frontend --create-namespace \
  --set image.repository=$ECR/mern-frontend --set imagePullSecret.name=ecr-creds \
  --set imagePullSecret.registry=$ECR --set imagePullSecret.username=AWS \
  --set imagePullSecret.password="$(aws ecr get-login-password --region ap-south-1)" \
  --set backendUrl=http://api.hobbyez.com
```

### 2.3 Validate
```bash
for ns in database backend frontend; do kubectl get pods -n $ns; done   # all Running 1/1
kubectl run t --rm -i --image=curlimages/curl:8.10.1 -n backend --restart=Never -- \
  curl -s http://backend:3000/healthz                        # {"status":"ok","dbStatus":"connected"}
```

---

## 3. North-south — nginx Ingress (`app.hobbyez.com`)

```bash
cd CICD
# 1+3. controller behind its own NLB (Service type=LoadBalancer)
./ingress-nginx/nginx-ingress-controller-install.sh
# 2. ingress resources (app.hobbyez.com -> frontend, api.hobbyez.com -> backend)
kubectl apply -f ingress-nginx/ingress.yaml
cd ..

# 4. Route53 alias: app/api.hobbyez.com -> the nginx NLB
# --- inputs (same idea as $NLB): the two hosted-zone ids route53-alias.sh needs ---
export ZONE=Z07010022C4LQ7Z9ZKUKL    # input: Route53 hosted zone id for hobbyez.com
export NLBZONE=ZVDDRBQ08TROA          # input: NLB canonical hosted zone id (ap-south-1)
NLB=$(kubectl get svc ingress-nginx-nginx-ingress-controller -n ingress-nginx -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
CICD/route53-alias.sh app.hobbyez.com api.hobbyez.com -- $NLB
# test
curl http://app.hobbyez.com/ -I        # 200
```
**Cleanup:** `kubectl delete -f CICD/ingress-nginx/ingress.yaml && helm uninstall ingress-nginx -n ingress-nginx`

---

## 4. North-south — Gateway API / Envoy (`gateway.hobbyez.com`)

```bash
cd CICD
./gateway-api/envoy-gateway-api-install.sh                 # Envoy Gateway + GatewayClass + NLB
kubectl apply -f gateway-api/gateway.yaml -f gateway-api/httproute.yaml
cd ..

export ZONE=Z07010022C4LQ7Z9ZKUKL    # input: Route53 hosted zone id for hobbyez.com
export NLBZONE=ZVDDRBQ08TROA          # input: NLB canonical hosted zone id (ap-south-1)
NLB=$(kubectl get svc -n envoy-gateway-system -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.loadBalancer.ingress[0].hostname}{"\n"}{end}' | awk '/mern-gateway/{print $2}')
CICD/route53-alias.sh gateway.hobbyez.com api-gateway.hobbyez.com -- $NLB
curl http://gateway.hobbyez.com/ -I    # 200
```
**Cleanup:** `kubectl delete -f CICD/gateway-api/gateway.yaml -f CICD/gateway-api/httproute.yaml && helm uninstall eg -n envoy-gateway-system`

---

## 5. North-south — Istio (`istio.hobbyez.com`)

Installed with **Helm** (charts: `base` + `istiod` in `istio-system`, `gateway` in `istio-ingress`) —
no `istioctl`, no release tarball.

```bash
cd CICD
./istio/istio-install.sh                                   # base + istiod + ingress gateway (NLB)
kubectl apply -f istio/gateway.yaml -f istio/virtualservice.yaml
cd ..

export ZONE=Z07010022C4LQ7Z9ZKUKL    # input: Route53 hosted zone id for hobbyez.com
export NLBZONE=ZVDDRBQ08TROA          # input: NLB canonical hosted zone id (ap-south-1)
NLB=$(kubectl get svc istio-ingressgateway -n istio-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
CICD/route53-alias.sh istio.hobbyez.com api-istio.hobbyez.com -- $NLB
curl http://istio.hobbyez.com/ -I      # 200
```
**Cleanup:** `kubectl delete -f CICD/istio/gateway.yaml -f CICD/istio/virtualservice.yaml && helm uninstall istio-ingressgateway -n istio-ingress && helm uninstall istiod istio-base -n istio-system`

---

## Full teardown
```bash
CICD/cleanup.sh        # app namespaces + all 3 controllers + Route53 records + NLBs
```

> Notes: ECR login token lasts ~12h (re-create `ecr-creds` to rotate). The 3 NLBs are
> billable. If the AWS account ever blocks LB creation, each controller has a
> NodePort/hostNetwork fallback noted in its install script.
