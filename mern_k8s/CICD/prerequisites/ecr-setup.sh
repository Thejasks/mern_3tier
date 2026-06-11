#!/usr/bin/env bash
# =============================================================================
# Generalised ECR setup — create repos, print push/pull commands, and wire the
# private registry into a Kubernetes cluster (image-pull secret).
#
# USAGE
#   ./ecr-setup.sh [repo ...]                 # defaults: mern-backend mern-frontend
#   REPOS="api web worker" ./ecr-setup.sh
#
# ENV VARS (all optional)
#   AWS_REGION     default ap-south-1
#   AWS_ACCOUNT    default: auto-detected from `aws sts get-caller-identity`
#   IMAGE_TAG      default: 1               (used in the example push/pull lines)
#   NAMESPACE      if set, also CREATE the k8s pull secret in this namespace
#   PULL_SECRET    name of the k8s pull secret              (default: ecr-creds)
#
# REQUIRES: aws CLI (configured), docker; kubectl only if NAMESPACE is set.
# =============================================================================
set -euo pipefail

AWS_REGION="${AWS_REGION:-ap-south-1}"
AWS_ACCOUNT="${AWS_ACCOUNT:-$(aws sts get-caller-identity --query Account --output text)}"
REGISTRY="${AWS_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com"
IMAGE_TAG="${IMAGE_TAG:-1}"
PULL_SECRET="${PULL_SECRET:-ecr-creds}"

# repos: positional args > $REPOS env > sensible default
if [ "$#" -gt 0 ]; then REPOS=("$@"); else read -r -a REPOS <<< "${REPOS:-mern-backend mern-frontend}"; fi

hr() { printf '%s\n' "-------------------------------------------------------------------------------"; }
say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

say "Registry: ${REGISTRY}   region: ${AWS_REGION}   repos: ${REPOS[*]}"

# -----------------------------------------------------------------------------
say "1) Creating ECR repositories (idempotent, scan-on-push enabled)"
for r in "${REPOS[@]}"; do
  if aws ecr describe-repositories --region "$AWS_REGION" --repository-names "$r" >/dev/null 2>&1; then
    echo "   exists: $r"
  else
    aws ecr create-repository --region "$AWS_REGION" --repository-name "$r" \
      --image-scanning-configuration scanOnPush=true \
      --query 'repository.repositoryUri' --output text
  fi
done

# -----------------------------------------------------------------------------
say "2) Docker login (run this once per shell before building/pushing)"
hr
echo "aws ecr get-login-password --region ${AWS_REGION} \\"
echo "  | docker login --username AWS --password-stdin ${REGISTRY}"
hr

# -----------------------------------------------------------------------------
say "3) Build / tag / push  and  pull commands (per repo)"
for r in "${REPOS[@]}"; do
  hr; echo "# ${r}"
  echo "  # build for the cluster's arch (EC2 = linux/amd64) and push:"
  echo "  docker buildx build --platform linux/amd64 \\"
  echo "    -t ${REGISTRY}/${r}:${IMAGE_TAG} -t ${REGISTRY}/${r}:latest --push ."
  echo
  echo "  # or classic build + push:"
  echo "  docker build -t ${REGISTRY}/${r}:${IMAGE_TAG} ."
  echo "  docker push ${REGISTRY}/${r}:${IMAGE_TAG}"
  echo
  echo "  # pull:"
  echo "  docker pull ${REGISTRY}/${r}:${IMAGE_TAG}"
done
hr

# -----------------------------------------------------------------------------
say "4) Wire ECR into Kubernetes — TWO methods (demo both)"
cat <<EOF

============================ METHOD 1: imagePullSecret =========================
Works on ANY cluster. A docker-registry secret holds an ECR token. The token
expires in ~12h (AWS-fixed), so it must be rotated — fine for a demo, or use the
CronJob below to keep it fresh forever.

  # a) create the secret (per namespace that runs ECR images)
  kubectl create namespace <ns> --dry-run=client -o yaml | kubectl apply -f -
  kubectl create secret docker-registry ${PULL_SECRET} -n <ns> \\
    --docker-server=${REGISTRY} \\
    --docker-username=AWS \\
    --docker-password="\$(aws ecr get-login-password --region ${AWS_REGION})" \\
    --dry-run=client -o yaml | kubectl apply -f -

  # b) reference it — per Deployment:
  #   spec.template.spec.imagePullSecrets: [{ name: ${PULL_SECRET} }]
  # OR attach to the namespace default ServiceAccount (covers every pod):
  kubectl patch serviceaccount default -n <ns> \\
    -p '{"imagePullSecrets":[{"name":"${PULL_SECRET}"}]}'

  # c) keep it fresh automatically (CronJob re-mints the token every 8h).
  #    Needs an SA that can write the secret + AWS creds. Quick version using an
  #    IAM user access key stored as a secret:
  kubectl create secret generic ecr-refresher-aws -n <ns> \\
    --from-literal=AWS_ACCESS_KEY_ID=AKIA... \\
    --from-literal=AWS_SECRET_ACCESS_KEY=...
  kubectl apply -n <ns> -f - <<'CRON'
  apiVersion: v1
  kind: ServiceAccount
  metadata: { name: ecr-refresher }
  ---
  apiVersion: rbac.authorization.k8s.io/v1
  kind: Role
  metadata: { name: ecr-refresher }
  rules:
    - apiGroups: [""]
      resources: ["secrets"]
      verbs: ["get","create","update","patch","delete"]
  ---
  apiVersion: rbac.authorization.k8s.io/v1
  kind: RoleBinding
  metadata: { name: ecr-refresher }
  roleRef: { apiGroup: rbac.authorization.k8s.io, kind: Role, name: ecr-refresher }
  subjects: [{ kind: ServiceAccount, name: ecr-refresher }]
  ---
  apiVersion: batch/v1
  kind: CronJob
  metadata: { name: ecr-creds-refresh }
  spec:
    schedule: "0 */8 * * *"        # every 8h (token lives 12h)
    jobTemplate:
      spec:
        template:
          spec:
            serviceAccountName: ecr-refresher
            restartPolicy: OnFailure
            containers:
              - name: refresh
                image: amazon/aws-cli:2.17.0
                envFrom: [{ secretRef: { name: ecr-refresher-aws } }]
                env: [{ name: AWS_DEFAULT_REGION, value: ${AWS_REGION} }]
                command: ["/bin/sh","-c"]
                args:
                  - |
                    yum install -y kubectl >/dev/null 2>&1 || true
                    TOKEN=\$(aws ecr get-login-password)
                    kubectl create secret docker-registry ${PULL_SECRET} \\
                      --docker-server=${REGISTRY} --docker-username=AWS --docker-password="\$TOKEN" \\
                      --dry-run=client -o yaml | kubectl apply -f -
  CRON

=================== METHOD 2: kubelet ECR credential provider ==================
The "real" production fix on self-managed clusters (what EKS does for you).
NO secret, NO expiry — kubelet uses the NODE IAM role to fetch ECR creds on each
pull and auto-refreshes forever. Run ONCE PER NODE (add to your node setup script).
Prereq: nodes have an IAM role with AmazonEC2ContainerRegistryReadOnly
        (install/aws-load-balancer-controller.sh attaches exactly this).

  sudo mkdir -p /etc/kubernetes/image-credential-provider
  cd /etc/kubernetes/image-credential-provider
  ARCH=\$(uname -m); case \$ARCH in x86_64) ARCH=amd64;; aarch64) ARCH=arm64;; esac
  sudo curl -fsSLo ecr-credential-provider \\
    https://artifacts.k8s.io/binaries/cloud-provider-aws/v1.31.0/linux/\${ARCH}/ecr-credential-provider-linux-\${ARCH}
  sudo chmod +x ecr-credential-provider
  cat <<'CFG' | sudo tee config.yaml
  apiVersion: kubelet.config.k8s.io/v1
  kind: CredentialProviderConfig
  providers:
    - name: ecr-credential-provider
      matchImages: ["*.dkr.ecr.*.amazonaws.com"]
      defaultCacheDuration: "12h"
      apiVersion: credentialprovider.kubelet.k8s.io/v1
  CFG
  echo 'KUBELET_EXTRA_ARGS=--image-credential-provider-config=/etc/kubernetes/image-credential-provider/config.yaml --image-credential-provider-bin-dir=/etc/kubernetes/image-credential-provider' \\
    | sudo tee -a /var/lib/kubelet/kubeadm-flags.env
  sudo systemctl restart kubelet

  # After this, DELETE the secret + drop imagePullSecrets from the charts:
  #   kubectl delete secret ${PULL_SECRET} -n <ns>
================================================================================
EOF
hr

# -----------------------------------------------------------------------------
if [ -n "${NAMESPACE:-}" ]; then
  say "5) NAMESPACE set -> creating ${PULL_SECRET} in '${NAMESPACE}' now (Method 1)"
  kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
  kubectl create secret docker-registry "${PULL_SECRET}" -n "${NAMESPACE}" \
    --docker-server="${REGISTRY}" --docker-username=AWS \
    --docker-password="$(aws ecr get-login-password --region "${AWS_REGION}")" \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "   created secret/${PULL_SECRET} in ${NAMESPACE}"
else
  say "5) (skipped) set NAMESPACE=<ns> to auto-create the pull secret"
fi

say "Done. Repos: ${REPOS[*]/#/${REGISTRY}/}"
