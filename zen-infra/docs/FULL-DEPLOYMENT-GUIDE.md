# Zen Pharma — Full Deployment Guide

End-to-end automation for deploying the Zen Pharma platform.
All scripts prompt you for values — nothing is hardcoded.

---

## Architecture Overview

### Stage 1 — Infrastructure (zen-infra)

```
Engineer pushes infra change to zen-infra
        │
        ▼
┌─────────────────────────────────────────────────────────────┐
│  Pull Request to main                                        │
│                                                             │
│  GitHub Actions — Terraform Plan                            │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  fmt-check → init → validate → plan → upload artifact│   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
│  Plan output visible in Actions tab                         │
│  PR blocked from merge if plan fails                        │
└────────────────────────┬────────────────────────────────────┘
                         │ PR approved and merged to main
                         ▼
┌─────────────────────────────────────────────────────────────┐
│  GitHub Actions — Terraform Apply                            │
│                                                             │
│  plan (re-runs) ──► MANUAL APPROVAL GATE ──► apply         │
│                     (GitHub Environment       (15–25 min)   │
│                      protection rule)                       │
└────────────────────────┬────────────────────────────────────┘
                         │ Terraform creates AWS resources
                         ▼
┌─────────────────────────────────────────────────────────────┐
│  AWS Account (us-east-1)                                     │
│                                                             │
│  VPC (10.0.0.0/16)                                          │
│  ├── Public  subnets  10.0.1/2.0/24  ── NLB, NAT Gateway   │
│  ├── Private subnets  10.0.3/4.0/24  ── EKS worker nodes   │
│  └── Private subnets  10.0.5/6.0/24  ── RDS PostgreSQL      │
│                                                             │
│  EKS Cluster (pharma-dev-cluster, K8s 1.33)                 │
│  └── Managed node group  3 × t3.small  (min 1 / max 4)     │
│      └── OIDC provider enabled  (required for IRSA)         │
│                                                             │
│  RDS PostgreSQL (pharma-dev-postgres)                        │
│  └── db.t3.micro · 20 GB · encrypted · private subnet only  │
│                                                             │
│  ECR Repositories (one per service, scan-on-push enabled)   │
│  ├── api-gateway          ├── inventory-service             │
│  ├── auth-service         ├── supplier-service              │
│  ├── drug-catalog-service ├── manufacturing-service         │
│  ├── notification-service └── pharma-ui                     │
│                                                             │
│  IAM Roles                                                  │
│  ├── pharma-dev-gitlab-runner-role  (GitHub Actions → ECR)  │
│  │   Trust: repo zen-pharma-backend + zen-pharma-frontend   │
│  │   Perm:  ECR push/pull, EKS describe                     │
│  ├── pharma-dev-eso-role  (External Secrets Operator)       │
│  │   Trust: K8s SA external-secrets/external-secrets        │
│  │   Perm:  secretsmanager:GetSecretValue on /pharma/*      │
│  └── pharma-dev-argocd-role  (ArgoCD controller)            │
│      Trust: K8s SA argocd/argocd-application-controller     │
│                                                             │
│  Secrets Manager                                            │
│  ├── /pharma/dev/db-credentials  {username, password}       │
│  └── /pharma/dev/jwt-secret      {secret}                   │
└─────────────────────────────────────────────────────────────┘
```

---

### Stage 2 — Kubernetes Setup (scripts)

```
EKS cluster is running (Stage 1 complete)
        │
        ▼ ./scripts/01-install-prerequisites.sh
┌─────────────────────────────────────────────────────────────┐
│  Helm installs on EKS                                        │
│  ├── ingress-nginx  (ingress-nginx ns)  ── AWS NLB          │
│  ├── argocd         (argocd ns)         ── GitOps controller │
│  └── external-secrets (external-secrets ns) ── Secret sync  │
└────────────────────────┬────────────────────────────────────┘
                         │ ./scripts/02-bootstrap-argocd.sh
                         ▼
┌─────────────────────────────────────────────────────────────┐
│  ArgoCD configured                                           │
│  ├── zen-gitops repo registered (GitHub PAT)                 │
│  ├── pharma AppProject created                               │
│  └── Application manifests deployed (dev / qa / prod)       │
└────────────────────────┬────────────────────────────────────┘
                         │ ./scripts/03-setup-external-secrets.sh
                         ▼
┌─────────────────────────────────────────────────────────────┐
│  External Secrets wired to Secrets Manager (IRSA)            │
│  ├── ESO service account annotated with IAM role ARN         │
│  ├── ClusterSecretStore created (no static AWS keys)         │
│  └── ExternalSecrets → db-credentials + jwt-secret synced   │
└─────────────────────────────────────────────────────────────┘
```

---

### Stage 3 & 4 — CI/CD and Deploy

```
Developer pushes code
        │
        ▼
┌─────────────────────────────────────────────────────┐
│  Stage 3: GitHub Actions CI  (zen-pharma-backend)    │
│  secret-scan → test → SAST → build → image-scan     │
│                             → ECR push → gitops tag  │
└────────────────────────┬────────────────────────────┘
                         │ commits new image tag to zen-gitops
                         ▼
              zen-gitops (envs/<env>/values-*.yaml)
                         │
                         ▼ ArgoCD detects drift
┌─────────────────────────────────────────────────────┐
│  Stage 4: ArgoCD CD                                  │
│  render Helm → apply manifests → rolling update      │
└────────────────────────┬────────────────────────────┘
                         │
                         ▼
           AWS EKS Cluster (dev / qa / prod)
           │
           ├── Internet ──► NLB ──► ingress-nginx
           │                            │
           │              ┌─────────────┴──────────────┐
           │              │                            │
           │         pharma-ui                    api-gateway
           │         (React, :80)              (Spring Boot, :8080)
           │                                        │
           │               ┌────────────────────────┤
           │               │                        │
           │        auth-service (:8081)    drug-catalog-svc (:8082)
           │        inventory-svc (:8083)   supplier-svc (:8084)
           │        manufacturing-svc (:8085) notification-svc (:3000)
           │               │
           │               ▼
           │        RDS PostgreSQL (private subnet)
           │
           └── Secrets pulled from AWS Secrets Manager
               via External Secrets Operator (IRSA — no static keys)
```

---

## Stage Overview

| Stage | What | How | Automation |
|---|---|---|---|
| 1 | Provision AWS infrastructure | Terraform + GitHub Actions | `zen-infra/.github/workflows/terraform.yml` |
| 2 | Install K8s pre-requisites | Interactive bash scripts | `scripts/01` → `scripts/02` → `scripts/03` |
| 3 | Build, scan, and push images | GitHub Actions CI | `zen-pharma-backend/.github/workflows/ci-*.yml` |
| 4 | Deploy to EKS | ArgoCD GitOps (automatic) | ArgoCD watches zen-gitops, syncs on every commit |

---

## Stage 1 — Infrastructure via Terraform + GitHub Actions

Terraform provisions: VPC, EKS cluster, RDS PostgreSQL, ECR repositories,
IAM roles for OIDC (GitHub Actions) and IRSA (External Secrets Operator).

All Terraform operations run through GitHub Actions — no manual `terraform` commands needed.

### Step 1.1 — One-time: Create the S3 state bucket

The remote backend must exist before GitHub Actions can run `terraform init`.
This is the only step that cannot be automated by the pipeline itself.

```bash
# Replace <your-bucket-name> with your own unique name (e.g. zen-pharma-tfstate-yourname)
# Replace <your-region> with your AWS region (e.g. us-east-1)

aws s3api create-bucket \
  --bucket <your-bucket-name> \
  --region <your-region>

aws s3api put-bucket-versioning \
  --bucket <your-bucket-name> \
  --versioning-configuration Status=Enabled

aws s3api put-public-access-block \
  --bucket <your-bucket-name> \
  --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```

Update `zen-infra/envs/dev/backend.tf` with your bucket name and region.

### Step 1.2 — Set secrets in the `zen-infra` repo

Go to **GitHub → zen-infra → Settings → Secrets and variables → Actions** and add:

| Secret | Description |
|---|---|
| `AWS_ACCESS_KEY_ID` | IAM user access key with permissions to create EKS, RDS, ECR, IAM |
| `AWS_SECRET_ACCESS_KEY` | IAM user secret key |
| `DEV_DB_PASSWORD` | Password for the RDS PostgreSQL instance |
| `DEV_JWT_SECRET` | Secret key used to sign JWT tokens |

### Step 1.3 — Push zen-infra to GitHub and open a PR

```bash
cd zen-infra
git add .
git commit -m "feat: initial terraform infrastructure"
git push origin main
```

When you push, GitHub Actions automatically runs `terraform plan`.

### Step 1.4 — Terraform workflow steps (what happens automatically)

**On a PR to `main`:**

```
1. Checkout code
2. Setup Terraform 1.10.0
3. Configure AWS credentials (from repo secrets)
4. terraform fmt -check        → fails if formatting is wrong
5. terraform init              → connects to S3 backend, downloads providers
6. terraform validate          → checks configuration syntax and logic
7. terraform plan              → shows what will be created/changed/destroyed
                                 saved as artifact (tfplan)
8. Status check → blocks PR merge if plan failed
```

**On merge to `main` (after PR is approved):**

```
1-7. Same as PR (re-runs plan to ensure fresh state)
8.   Upload plan artifact
9.   ── PAUSE: Manual approval gate ──
       GitHub Environment "dev" requires a reviewer to approve
       Go to: Actions → this run → Review deployments → Approve
10.  terraform apply tfplan    → provisions all AWS resources
     ┌─────────────────────────────────────────────────────────┐
     │  Resources created:                                     │
     │  • VPC + subnets + security groups                     │
     │  • EKS cluster + node groups                           │
     │  • RDS PostgreSQL instance                              │
     │  • ECR repositories (one per service)                  │
     │  • IAM OIDC provider (for GitHub Actions keyless auth) │
     │  • IAM role: pharma-github-actions-role (CI/CD)        │
     │  • IAM role: pharma-dev-eso-role (External Secrets)    │
     │  • AWS Secrets Manager entries for DB and JWT          │
     └─────────────────────────────────────────────────────────┘
```

**On `workflow_dispatch` (manual trigger):**

Go to **GitHub → zen-infra → Actions → Terraform Infrastructure → Run workflow**

Select action:
- `plan` — dry run, shows changes without applying
- `apply` — applies the last plan (requires approval gate)
- `destroy` — destroys all resources (type "destroy" in confirm field to proceed)

**If Terraform fails (state lock):**

```bash
aws s3 rm s3://<your-bucket-name>/envs/dev/terraform.tfstate.tflock
```

### Step 1.5 — Verify infrastructure was created

```bash
# Get cluster name from Terraform outputs or AWS console
aws eks list-clusters --region <your-region>

# Configure kubectl
aws eks update-kubeconfig \
  --region <your-region> \
  --name <your-cluster-name>

# Verify nodes are ready
kubectl get nodes
```

---

## Stage 2 — Install Kubernetes Pre-requisites

After the EKS cluster is running, install three cluster-level components.
All scripts prompt you for values — no hardcoding required.

### Step 2.1 — Install NGINX Ingress, ArgoCD, External Secrets Operator

```bash
./scripts/01-install-prerequisites.sh
```

The script prompts for:
- EKS cluster name
- AWS region

Then installs:

| Component | Namespace | Purpose |
|---|---|---|
| ingress-nginx | `ingress-nginx` | AWS NLB exposes services to the internet |
| argocd | `argocd` | Watches zen-gitops, syncs manifests to EKS |
| external-secrets | `external-secrets` | Pulls secrets from AWS Secrets Manager |

At the end, the script prints the **ArgoCD admin password** — save it.

### Step 2.2 — Register zen-gitops repo and deploy ArgoCD Applications

```bash
./scripts/02-bootstrap-argocd.sh
```

The script prompts for:
- Target environment (`dev` / `qa` / `prod`)
- GitOps repo HTTPS URL (e.g. `https://github.com/your-github-username/zen-gitops.git`)
- Your GitHub username
- GitHub Personal Access Token (input hidden) — needs read access to zen-gitops

Then:
1. Registers zen-gitops as a repository in ArgoCD
2. Creates the `pharma` AppProject (scoped to dev/qa/prod namespaces)
3. Applies ArgoCD Application manifests for the target environment

ArgoCD app layout per environment:

| Environment | App structure | Sync policy |
|---|---|---|
| `dev` | 8 individual Applications (one per service) | Automated + selfHeal |
| `qa` | 1 `pharma-qa` app pointing to `envs/qa/` | Automated + selfHeal |
| `prod` | 1 `pharma-prod` app pointing to `envs/prod/` | **Manual sync** (intentional gate) |

### Step 2.3 — Configure External Secrets Operator

```bash
./scripts/03-setup-external-secrets.sh
```

The script prompts for:
- Target environment
- AWS region
- AWS account ID (12 digits)
- ESO IAM role name (created by Terraform — default: `pharma-<env>-eso-role`)

Then:
1. Annotates the ESO service account with the IRSA IAM role ARN
2. Restarts ESO pods to pick up the annotation
3. Creates a `ClusterSecretStore` (IRSA-based — no static credentials)
4. Creates `ExternalSecrets` for `db-credentials` and `jwt-secret`
5. Waits and confirms both secrets sync from AWS Secrets Manager

Secrets Manager paths (created by Terraform):

| Kubernetes Secret | AWS Secrets Manager path |
|---|---|
| `db-credentials` | `/pharma/<env>/db-credentials` |
| `jwt-secret` | `/pharma/<env>/jwt-secret` |

---

## Stage 3 — CI Pipeline via GitHub Actions

CI runs automatically on every push to `develop` or `release/**` branches.
No manual steps required after setting up secrets in the repos.

### Step 3.1 — Set secrets in `zen-pharma-backend` repo

Go to **GitHub → zen-pharma-backend → Settings → Secrets and variables → Actions** and add:

| Secret | Description |
|---|---|
| `AWS_ACCOUNT_ID` | Your 12-digit AWS account number |
| `GITOPS_TOKEN` | GitHub PAT with write access to zen-gitops |
| `SEMGREP_APP_TOKEN` | Semgrep Cloud token (optional — enables cloud dashboard) |
| `NVD_API_KEY` | NIST NVD API key (optional — faster OWASP database updates) |

Set this repository **variable** (not secret):

| Variable | Value |
|---|---|
| `GITOPS_REPO` | `your-github-username/zen-gitops` |

> No AWS access keys needed — CI authenticates to AWS via OIDC (keyless).

### Step 3.2 — CI pipeline stages (runs automatically on push)

```
git push origin develop
        │
        ▼
┌──────────────────────────────────────────────────────────────┐
│  1. Gitleaks — secret scan                                    │
│     Scans the commit for accidentally committed passwords     │
│     or API keys before anything else runs                    │
└──────────────────┬───────────────────────────────────────────┘
                   │
                   ▼
┌──────────────────────────────────────────────────────────────┐
│  2. Maven verify — tests + coverage gate                      │
│     • Compiles the service                                   │
│     • Runs unit and integration tests                        │
│     • PostgreSQL 15 sidecar for services that need a DB      │
│     • JaCoCo measures code coverage — fails if < 80%        │
│     • Uploads coverage report as artifact                    │
└──────────────────┬───────────────────────────────────────────┘
                   │
                   ▼
┌──────────────────────────────────────────────────────────────┐
│  3. CodeQL — Java SAST                                        │
│     • Instruments the Maven build to collect call-graph data │
│     • Runs security-extended query suite                     │
│     • Results appear in GitHub → Security → Code scanning    │
└──────────────────┬───────────────────────────────────────────┘
                   │
                   ▼
┌──────────────────────────────────────────────────────────────┐
│  4. Semgrep SAST                                              │
│     • Scans against java + owasp-top-ten rule sets           │
│     • Advisory (continue-on-error) — findings go to dashboard│
└──────────────────┬───────────────────────────────────────────┘
                   │
                   ▼
┌──────────────────────────────────────────────────────────────┐
│  5. OWASP Dependency Check                                    │
│     • Scans Maven dependencies against NIST NVD              │
│     • Reports CVEs with CVSS ≥ 7.0                          │
│     • Non-blocking — HTML report uploaded as artifact        │
│     • NVD database cached between runs for faster execution  │
└──────────────────┬───────────────────────────────────────────┘
                   │
                   ▼
┌──────────────────────────────────────────────────────────────┐
│  6. Docker build                                              │
│     • Base image: eclipse-temurin:17-jre (runtime only)      │
│     • Maven package ran in step 2 — only copies the JAR      │
│     • Runs as non-root user (UID/GID 1000)                   │
└──────────────────┬───────────────────────────────────────────┘
                   │
                   ▼
┌──────────────────────────────────────────────────────────────┐
│  7. Trivy — image vulnerability scan                          │
│     • Scans the built image for OS and library CVEs          │
│     • Fails on HIGH and CRITICAL severity                    │
│     • Results uploaded to GitHub Security tab (SARIF)        │
└──────────────────┬───────────────────────────────────────────┘
                   │
                   ▼
┌──────────────────────────────────────────────────────────────┐
│  8. Push to ECR                                               │
│     • Authenticates via OIDC (no static AWS keys)            │
│     • Tag format: sha-<7chars>  (e.g. sha-a1b2c3d)          │
│     • Immutable — maps directly to the git commit            │
└──────────────────┬───────────────────────────────────────────┘
                   │
                   ▼
┌──────────────────────────────────────────────────────────────┐
│  9. Cosign — keyless image signing                            │
│     • GitHub OIDC token → Fulcio CA issues short-lived cert  │
│     • Signature stored in Rekor transparency log             │
│     • No long-lived signing key stored anywhere              │
└──────────────────┬───────────────────────────────────────────┘
                   │
                   ▼
┌──────────────────────────────────────────────────────────────┐
│  10. Update image tag in zen-gitops                           │
│     • Commits to envs/dev/values-<service>.yaml              │
│     • Sets image.tag: sha-<7chars>                           │
│     • ArgoCD detects this change and syncs dev namespace     │
└──────────────────┬───────────────────────────────────────────┘
                   │
                   ▼
┌──────────────────────────────────────────────────────────────┐
│  11. Open QA promotion PR                                     │
│     • Creates branch: promote/qa/<service>/<tag>             │
│     • Opens PR in zen-gitops with QA checklist               │
│     • QA team reviews and merges → ArgoCD syncs qa namespace │
└──────────────────────────────────────────────────────────────┘
```

### Step 3.3 — PR checks (no ECR push)

On every PR to `develop` or `main`, a lighter workflow runs:
- Gitleaks + Maven tests + JaCoCo + CodeQL only
- No Docker build, no ECR push
- Blocks the PR if tests or coverage gate fails

### Step 3.4 — PROD promotion (manual trigger)

When QA sign-off is complete:

1. Go to **GitHub → zen-pharma-backend → Actions → Promote to PROD**
2. Click **Run workflow**
3. Select the service to promote
4. The workflow reads the image tag currently in `envs/qa/values-<service>.yaml`
5. Opens a PR in zen-gitops: `promote/prod/<service>/<tag>`
6. PR requires 2 approvals before merge
7. After merge, ArgoCD `pharma-prod` waits for **manual sync** (prod is not auto-synced)

---

## Stage 4 — CD via ArgoCD (Automatic)

ArgoCD is the only component that deploys to Kubernetes. GitHub Actions never runs `kubectl apply`.

### How ArgoCD works

```
zen-gitops receives a commit (image tag updated by CI or promotion PR merge)
        │
        ▼
ArgoCD polls zen-gitops every 3 minutes
(configure a GitHub webhook for instant trigger — see Troubleshooting)
        │
        ▼
ArgoCD compares the desired state (Git) vs actual state (cluster)
        │  if diff detected:
        ▼
ArgoCD renders Helm chart with the updated values file
        │
        ▼
ArgoCD applies the rendered Kubernetes manifests to the target namespace
        │
        ▼
Kubernetes performs a rolling update:
  • New pod starts up
  • readinessProbe must pass before traffic is sent to new pod
  • Old pod is terminated only after new pod is ready (zero-downtime)
  • HPA adjusts replica count if CPU exceeds threshold
```

### Environment promotion flow

```
┌──────────────────────────────────────────────────────────────────┐
│  DEV (automatic)                                                  │
│  CI push to develop → ECR tag → gitops commit → ArgoCD auto-sync│
└───────────────────────────────────┬──────────────────────────────┘
                                    │ CI opens QA promotion PR
                                    ▼
┌──────────────────────────────────────────────────────────────────┐
│  QA (manual PR merge)                                             │
│  QA team reviews PR in zen-gitops → merge → ArgoCD auto-sync    │
└───────────────────────────────────┬──────────────────────────────┘
                                    │ promote-prod.yml (workflow_dispatch)
                                    ▼
┌──────────────────────────────────────────────────────────────────┐
│  PROD (manual PR merge + manual ArgoCD sync)                      │
│  2 approvals required on PR → merge → manually sync in ArgoCD UI│
└──────────────────────────────────────────────────────────────────┘
```

### Access ArgoCD UI

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

Open `https://localhost:8080`, login as `admin`.

Get password:
```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo
```

---

## Stage 4 — Verify Deployment

Run at any time to confirm the environment is healthy:

```bash
./scripts/04-verify-deployment.sh
```

The script prompts for the target environment, then checks:

| Check | What is verified |
|---|---|
| Pods | All pods in the namespace are `Running` and `Ready` |
| ArgoCD | All Applications are `Synced` and `Healthy` |
| External Secrets | All ExternalSecrets show `SecretSynced` |
| Services/Ingress | Resources exist in the namespace |
| HTTP health | `/actuator/health` returns `200` for each service via NLB |

---

## Quick Reference — Full Run Order

```
STAGE 1 — INFRASTRUCTURE
─────────────────────────────────────────────────────────────
1. aws s3api create-bucket ...          ← one-time, manual
2. Push zen-infra to GitHub             ← triggers terraform plan
3. Open PR → GitHub Actions: terraform plan runs automatically
4. Merge PR → approval gate → terraform apply runs automatically

STAGE 2 — KUBERNETES SETUP
─────────────────────────────────────────────────────────────
5. ./scripts/01-install-prerequisites.sh   ← prompts: cluster name, region
6. ./scripts/02-bootstrap-argocd.sh        ← prompts: env, gitops URL, token
7. ./scripts/03-setup-external-secrets.sh  ← prompts: env, account ID, role

STAGE 3 — CI (automatic after secrets are set)
─────────────────────────────────────────────────────────────
8. Set secrets in zen-pharma-backend repo (AWS_ACCOUNT_ID, GITOPS_TOKEN)
9. git push origin develop → CI runs all 11 stages automatically

STAGE 4 — CD (automatic via ArgoCD)
─────────────────────────────────────────────────────────────
10. ArgoCD detects gitops changes and deploys to dev automatically

VERIFY
─────────────────────────────────────────────────────────────
11. ./scripts/04-verify-deployment.sh      ← prompts: env
```

---

## Troubleshooting

### Pod stuck in `CreateContainerConfigError`

Secret not synced. Check:
```bash
kubectl describe externalsecret db-credentials -n <env>
kubectl get secret db-credentials -n <env>
```

### Pod in `CrashLoopBackOff`

```bash
kubectl logs -n <env> deployment/<service-name> --previous
```

### ArgoCD app stuck in `OutOfSync`

```bash
kubectl patch application <app-name> -n argocd \
  --type merge -p '{"operation":{"sync":{"revision":"HEAD"}}}'
```

### Terraform state lock

```bash
aws s3 rm s3://<your-bucket-name>/envs/dev/terraform.tfstate.tflock
```

### CI OIDC auth failure

Verify the IAM role trust policy covers your GitHub repo:
```bash
aws iam get-role --role-name pharma-github-actions-role \
  --query 'Role.AssumeRolePolicyDocument'
```

### ArgoCD polling too slow (3-minute lag)

Add a GitHub webhook from zen-gitops to trigger ArgoCD instantly:
1. Get ArgoCD URL (from your ingress or NLB hostname)
2. GitHub → zen-gitops → Settings → Webhooks → Add webhook
3. Payload URL: `https://<argocd-url>/api/webhook`
4. Content type: `application/json`
5. Events: `Push` only

---

## Service Port Reference

| Service | Port | Health endpoint |
|---|---|---|
| pharma-ui | 80 | `/` |
| api-gateway | 8080 | `/api/actuator/health` |
| auth-service | 8081 | `/actuator/health` |
| drug-catalog-service | 8082 | `/actuator/health` |
| inventory-service | 8083 | `/actuator/health` |
| supplier-service | 8084 | `/actuator/health` |
| manufacturing-service | 8085 | `/actuator/health` |
| notification-service | 3000 | `/health` |
