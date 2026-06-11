# ECR — build & push (quick reference)

```bash
# vars
AWS_REGION=ap-south-1
ACCOUNT=637423622313
REPO=mern-backend
REGISTRY=$ACCOUNT.dkr.ecr.$AWS_REGION.amazonaws.com
TAG=1                      # in CI: git SHA or build number — never "latest" for prod
```

### 1. Create the repo (one time)
```bash
aws ecr create-repository --repository-name $REPO --region $AWS_REGION
```

### 2. Get an ECR token & log Docker in (token valid ~12h)
```bash
aws ecr get-login-password --region $AWS_REGION \
  | docker login --username AWS --password-stdin $REGISTRY
```

### 3. Build
```bash
docker build -t $REGISTRY/$REPO:$TAG .
# Apple Silicon -> EC2 (amd64):
# docker buildx build --platform linux/amd64 -t $REGISTRY/$REPO:$TAG --push .
```

### 4. Push
```bash
docker push $REGISTRY/$REPO:$TAG
```

Pull is the same: `docker pull $REGISTRY/$REPO:$TAG`.

---

## Is this how companies do it in Jenkins / GitHub Actions?

**Yes — same 4 steps.** The only real difference: CI authenticates with an **IAM role**, not your laptop's keys, and tags with a **commit SHA / build number** (not `latest`).

**GitHub Actions** (OIDC role, no stored secrets):
```yaml
- uses: aws-actions/configure-aws-credentials@v4
  with:
    role-to-assume: arn:aws:iam::637423622313:role/gha-ecr
    aws-region: ap-south-1
- uses: aws-actions/amazon-ecr-login@v2          # = step 2 above
- run: |
    docker build -t $REGISTRY/$REPO:${{ github.sha }} .
    docker push $REGISTRY/$REPO:${{ github.sha }}
```

**Jenkins** (agent uses an EC2 instance role or `withAWS` creds):
```groovy
sh '''
  aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $REGISTRY
  docker build -t $REGISTRY/$REPO:$BUILD_NUMBER .
  docker push  $REGISTRY/$REPO:$BUILD_NUMBER
'''
```

Key points:
- **Auth in CI = IAM role**, not `aws configure` keys. Token still comes from `aws ecr get-login-password`.
- **Tag = immutable** (`${GIT_SHA}` / `${BUILD_NUMBER}`); the GitOps repo is then bumped to that tag.
- The ECR login token lasts ~12h — CI mints a fresh one each run, so it never matters.
- In real pipelines a scan step (Trivy / ECR scan-on-push) usually sits between build and push.
