# Terraform Interview Questions — DevOps Engineer

40 questions covering core concepts, state management, modules, CI/CD, and real-world scenarios.
Questions marked with 🏗️ include references to the zen-infra project architecture.

---

## Table of Contents

1. [Core Concepts](#section-1--core-concepts) (Q1–Q12)
2. [State & Backend](#section-2--state--backend) (Q13–Q19)
3. [Modules & Code Structure](#section-3--modules--code-structure) (Q20–Q24)
4. [CI/CD & Team](#section-4--cicd--team) (Q25–Q29)
5. [Scenario-Based](#section-5--scenario-based) (Q30–Q40)

---

## Section 1 — Core Concepts

### Q1. What is Terraform state and why is it important? 🏗️

State is Terraform's source of truth — it maps what's in your config to what actually exists in AWS. Without it, Terraform has no idea what it already created. Every `plan` would try to create everything from scratch, and every `apply` would result in duplicate resources.

In zen-infra, each environment has its own isolated state file in S3:

```
envs/dev/terraform.tfstate
envs/qa/terraform.tfstate
envs/prod/terraform.tfstate
```

This gives full isolation — a failed apply in dev has zero impact on prod state.

---

### Q2. What are providers in Terraform? How do you manage provider versions?

Providers are plugins that let Terraform talk to external APIs — AWS, Kubernetes, GitHub, etc. Every resource belongs to a provider. You declare them in `providers.tf` and Terraform downloads them on `terraform init`.

Version management matters because provider updates can introduce breaking changes. You pin versions using `required_providers`:

```hcl
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"   # allows 5.x but not 6.x
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
  }
}
```

The `~>` operator is called a pessimistic constraint — it allows patch and minor updates but blocks major version bumps. In zen-infra we also use Dependabot to open PRs automatically when new provider versions are released, so updates go through PR review rather than being applied blindly.

---

### Q3. Explain resource vs data source in Terraform. 🏗️

A **resource** creates, updates, or destroys infrastructure. Terraform owns it.
A **data source** reads existing infrastructure that Terraform didn't create. It is read-only.

```hcl
# Resource — Terraform creates and manages this
resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
}

# Data source — reads something that already exists
data "aws_caller_identity" "current" {}

output "account_id" {
  value = data.aws_caller_identity.current.account_id
}
```

In zen-infra we use `data "aws_caller_identity" "current"` to dynamically fetch the AWS account ID without hardcoding it — useful when the same code runs across multiple AWS accounts.

---

### Q4. What is terraform.tfvars vs variables.tf?

These are two different things that work together:

| File | Purpose |
|---|---|
| `variables.tf` | **Declares** variables — name, type, description, optional default |
| `terraform.tfvars` | **Assigns** values to those declared variables |

```hcl
# variables.tf — declaration only
variable "db_password" {
  description = "RDS master password"
  type        = string
  sensitive   = true
}

# terraform.tfvars — actual values
db_password = "mysecretpassword"
```

**Important:** Never commit `terraform.tfvars` to git if it contains secrets. In zen-infra we don't use tfvars files for secrets at all — passwords come from GitHub Secrets at pipeline runtime and are passed directly:

```yaml
terraform plan -var="db_password=${{ secrets.DEV_DB_PASSWORD }}"
```

---

### Q5. What are input variables, locals, and outputs?

Three different ways to handle values in Terraform:

- **Variables** — inputs from outside the module; the caller decides the value
- **Locals** — computed intermediate values, only visible within the same module
- **Outputs** — values exported from a module so other modules or callers can consume them

```hcl
variable "env" {
  type = string   # caller passes "dev" or "prod"
}

locals {
  name_prefix = "pharma-${var.env}"   # computed internally, not exposed
}

resource "aws_vpc" "main" {
  tags = { Name = "${local.name_prefix}-vpc" }
}

output "vpc_id" {
  value = aws_vpc.main.id   # exposed for other modules to reference
}
```

In zen-infra the VPC module outputs `vpc_id`, `private_eks_subnet_ids`, and `private_rds_subnet_ids` — and the EKS and RDS modules consume those outputs as inputs.

---

### Q6. What is count vs for_each? When do you use each?

`count` creates N resources indexed by number. `for_each` iterates over a map or set, keying each resource by a stable identifier.

```hcl
# count — risky if order changes
resource "aws_instance" "server" {
  count = 3
  # creates server[0], server[1], server[2]
}

# for_each — stable, named keys
resource "aws_ecr_repository" "main" {
  for_each = toset(var.repositories)
  name     = each.key
}
```

The danger with `count`: if you remove an item from the middle of the list, Terraform re-indexes everything after it and destroys/recreates those resources unnecessarily.

With `for_each`, each resource has a stable key — removing one item only affects that one resource.

In zen-infra the ECR module uses `for_each` to create one repository per service:

```hcl
for_each = toset(["api-gateway", "auth-service", "drug-catalog-service", ...])
```

Removing `drug-catalog-service` only destroys that one repo, not the entire list.

---

### Q7. What is a dynamic block in Terraform?

`dynamic` generates repeated nested blocks programmatically — useful when the number of nested blocks depends on a variable.

```hcl
variable "ingress_rules" {
  type = list(object({
    port     = number
    protocol = string
  }))
}

resource "aws_security_group" "main" {
  dynamic "ingress" {
    for_each = var.ingress_rules
    content {
      from_port   = ingress.value.port
      to_port     = ingress.value.port
      protocol    = ingress.value.protocol
      cidr_blocks = ["0.0.0.0/0"]
    }
  }
}
```

Without `dynamic`, you would have to hardcode every `ingress {}` block. With it, you pass a list and Terraform generates them. Common use cases: security group rules, IAM policy statements, EKS add-ons.

---

### Q8. What is the lifecycle block?

`lifecycle` controls how Terraform creates, updates, and deletes resources.

```hcl
resource "aws_db_instance" "main" {
  ...
  lifecycle {
    create_before_destroy = true          # provision new before destroying old
    prevent_destroy       = true          # block terraform destroy — safety for prod
    ignore_changes        = [engine_version]  # ignore external changes to this field
  }
}
```

- **`create_before_destroy`** — eliminates downtime during replacement. Terraform creates the new resource first, then destroys the old one.
- **`prevent_destroy`** — great for production databases and S3 state buckets. If someone runs `destroy`, Terraform errors out instead of proceeding.
- **`ignore_changes`** — useful when something outside Terraform modifies an attribute and you don't want Terraform to revert it on every plan.

---

### Q9. What is depends_on and when is it actually needed?

Terraform builds a dependency graph automatically from resource references. `depends_on` is only needed when there is a dependency Terraform cannot detect from the code — typically IAM policies that must exist before a resource can use them.

```hcl
resource "aws_eks_cluster" "main" {
  depends_on = [
    aws_iam_role_policy_attachment.cluster_policy
  ]
}
```

Without `depends_on` here, Terraform might try to create the EKS cluster before the IAM policy attachment is complete. The resource reference alone does not signal that ordering requirement.

Real talk: if you find yourself using `depends_on` heavily, it is often a sign the module structure needs rethinking. The reference-based graph handles 95% of cases automatically.

---

### Q10. What is dependency management in Terraform? 🏗️

Terraform resolves dependencies in three ways:

1. **Implicit** — when resource A references an output of resource B, Terraform knows B must exist first
2. **Explicit** — `depends_on` for cases the graph cannot detect
3. **Module outputs** — passing an output from one module as an input to another forces ordering

```hcl
# zen-infra implicit dependency chain
module "vpc" { ... }

module "eks" {
  subnet_ids = module.vpc.private_eks_subnet_ids  # EKS waits for VPC
}

module "rds" {
  subnet_ids            = module.vpc.private_rds_subnet_ids    # RDS waits for VPC
  eks_security_group_id = module.eks.cluster_security_group_id # RDS waits for EKS SG
}
```

Terraform parallelises everything it can — resources with no dependency on each other are created simultaneously. That is why a full `terraform apply` on zen-infra is faster than it looks — VPC, ECR, IAM, and Secrets Manager all start in parallel.

---

### Q11. What does terraform init do?

It initialises the working directory — downloads providers, connects to the remote backend, and fetches modules. Must be re-run whenever you:

- Add a new provider
- Change the backend config
- Add or update a module source

```bash
cd envs/dev
terraform init
# Downloads aws, kubernetes, tls providers
# Connects to S3 backend
# Downloads module sources
```

In a CI pipeline always run `init` before `plan` — the runner starts fresh every time and has no local providers or state.

---

### Q12. What is the difference between terraform validate, terraform fmt, and terraform plan? 🏗️

| Command | What it checks | Calls AWS? |
|---|---|---|
| `terraform fmt` | Formatting only — indentation, spacing | No |
| `terraform validate` | Syntax and logic — types, required args, valid references | No |
| `terraform plan` | Full dry-run comparing config against real infrastructure | Yes |

In zen-infra's pipeline all three run in sequence before apply:

```yaml
- run: terraform fmt -check -recursive   # fails fast on formatting issues
- run: terraform validate                # catches config errors without an API call
- run: terraform plan -out=tfplan        # full comparison against live AWS
```

Each catches a different class of error. `fmt` is instant. `validate` takes seconds. `plan` can take minutes — so you do not want it running unnecessarily.

---

## Section 2 — State & Backend

### Q13. What is a remote backend and why do you need it? 🏗️

By default state is stored locally — which breaks completely for teams. Anyone else running `plan` does not see your state, two people applying simultaneously corrupt it, and the file is lost if the machine is gone.

A remote backend like S3 solves all three:

```hcl
# envs/dev/backend.tf in zen-infra
terraform {
  backend "s3" {
    bucket       = "zen-pharma-terraform-state"
    key          = "envs/dev/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true   # S3 native locking — no DynamoDB needed (Terraform ≥ 1.10)
  }
}
```

State locking ensures only one operation runs at a time. If a second `apply` tries to start while one is running, it fails immediately with a clear error showing who holds the lock and since when.

---

### Q14. What is the difference between terraform refresh and terraform plan?

`terraform refresh` syncs state with reality — it queries AWS and updates the state file to match the current actual state of resources, without making any infrastructure changes.

`terraform plan` reads the config, reads state (after an implicit refresh), and computes the diff — what needs to be created, updated, or destroyed.

```bash
# Sync state with real AWS — updates .tfstate but touches nothing in AWS
terraform refresh

# Show what needs to change — includes a refresh by default
terraform plan

# Refresh-only plan — shows drift without proposing any changes
terraform apply -refresh-only
```

In Terraform ≥ 0.15, `plan` includes a refresh by default. Use `terraform plan -refresh=false` for faster plans when you know nothing has changed externally. Use `-refresh-only` when you suspect drift and want to review it before deciding what to do.

---

### Q15. How do you check what resources are tracked in the Terraform state file?

```bash
# List all resources in state
terraform state list

# Example output
module.vpc.aws_vpc.main
module.vpc.aws_subnet.public[0]
module.vpc.aws_nat_gateway.main
module.eks.aws_eks_cluster.main
module.eks.aws_eks_node_group.main
module.rds.aws_db_instance.main
module.ecr.aws_ecr_repository.main["api-gateway"]
module.ecr.aws_ecr_repository.main["auth-service"]

# Inspect a specific resource in detail
terraform state show module.eks.aws_eks_cluster.main

# Pull the full state as JSON
terraform show -json > state.json
```

`state list` is the first command to run when troubleshooting — it tells you exactly what Terraform knows about and how each resource is addressed. If a resource is not in that list, Terraform does not know it exists.

---

### Q16. What is terraform state mv and when do you use it?

`state mv` moves a resource in state from one address to another without touching real infrastructure. The resource keeps existing in AWS — only its entry in the state file changes.

```bash
# Rename a resource block in code
terraform state mv aws_s3_bucket.old_name aws_s3_bucket.new_name

# Move a resource into a module
terraform state mv aws_vpc.main module.vpc.aws_vpc.main

# Move between modules
terraform state mv module.old.aws_subnet.eks module.vpc.aws_subnet.private_eks
```

Without `state mv`, Terraform sees the old address as deleted and the new address as something to create — it would destroy and recreate the resource. For an EKS cluster or RDS instance, that is catastrophic. Always `state mv` first, then update the code, then run `plan` to confirm zero changes.

---

### Q17. What is terraform import? How do you bring existing infrastructure under Terraform?

`terraform import` pulls an existing AWS resource into Terraform state so Terraform can manage it going forward.

```bash
# Import an existing VPC
terraform import module.vpc.aws_vpc.main vpc-0abc123def456789

# Import an existing RDS instance
terraform import module.rds.aws_db_instance.main pharma-dev-postgres
```

**The limitation everyone hits:** `import` only updates the state file. You still need to write the matching Terraform config manually — and it must match exactly what is in AWS, or the next `plan` will show changes.

Terraform 1.5+ introduced `import` blocks in config:

```hcl
import {
  to = aws_vpc.main
  id = "vpc-0abc123def456789"
}
```

Combined with `terraform plan -generate-config-out=generated.tf`, Terraform can now scaffold the config for you. It still needs review and cleanup but saves significant manual effort.

---

### Q18. What is state file corruption? How do you prevent and fix it?

Corruption happens when two `apply` operations write to state simultaneously, or a process crashes mid-write.

**Prevention:**
- Always use remote state with locking — this is the primary protection
- Never manually edit the state file directly
- Enable S3 versioning on your state bucket — every state change creates a new recoverable version

**If corruption happens:**

```bash
# Check if state is actually broken
terraform plan

# Restore a previous version from S3
# AWS Console → S3 → state bucket → show versions → restore previous version

# Force-unlock a stuck lock (only when no apply is genuinely running)
terraform force-unlock <lock-id>
```

In zen-infra the S3 backend has `encrypt = true` and S3 versioning enabled so any bad state write can be rolled back. Force-unlock should be a last resort — running it while an apply is genuinely in progress guarantees corruption.

---

### Q19. How do you manage Terraform state in AWS? What are the best practices? 🏗️

The standard pattern is S3 with locking and one state file per environment:

```
S3 bucket: zen-pharma-terraform-state
├── envs/dev/terraform.tfstate
├── envs/qa/terraform.tfstate
└── envs/prod/terraform.tfstate
```

Best practices used in zen-infra:

| Practice | Implementation |
|---|---|
| Separate state per environment | Unique `key` per `backend.tf` |
| State locking | `use_lockfile = true` (Terraform ≥ 1.10, no DynamoDB needed) |
| Encryption at rest | `encrypt = true` |
| Version recovery | S3 versioning enabled on the bucket |
| Restricted access | Only the pipeline IAM role can write to the state bucket |
| No local state in CI | Runner is ephemeral — remote backend only |

---

## Section 3 — Modules & Code Structure

### Q20. What are Terraform modules and how do you version them? 🏗️

A module is a reusable, self-contained package of Terraform config with inputs (variables) and outputs. You call the same module multiple times with different inputs.

In zen-infra the same VPC module is called from all three environments:

```hcl
# envs/dev/main.tf
module "vpc" {
  source  = "../../modules/vpc"
  project = "pharma"
  env     = "dev"
  vpc_cidr = "10.0.0.0/16"
}

# envs/prod/main.tf — same module, different values
module "vpc" {
  source  = "../../modules/vpc"
  project = "pharma"
  env     = "prod"
  vpc_cidr = "10.1.0.0/16"
}
```

**Versioning options:**

```hcl
# Local path — versions with the repo via git tags
source = "../../modules/vpc"

# Git with pinned tag — for shared modules across repos
source = "git::https://github.com/org/terraform-modules.git//vpc?ref=v2.1.0"

# Terraform Registry
source  = "terraform-aws-modules/vpc/aws"
version = "~> 5.0"
```

For shared internal modules, git tags are the cleanest approach — `ref=v2.1.0` pins exactly what was tested.

---

### Q21. Multi-environment design — separate folders vs workspaces. Which do you choose? 🏗️

**Workspaces** share the same code and backend path — just different state files. The problems:
- One codebase means you cannot have environment-specific configs easily
- Easy to be in the wrong workspace and apply to prod when you meant dev
- No path-based pipeline triggers — one change affects all environments

**Separate directories** give full isolation:

```
envs/
├── dev/    ← own backend.tf, variables, pipeline trigger on envs/dev/**
├── qa/     ← own backend.tf, variables, pipeline trigger on envs/qa/**
└── prod/   ← own backend.tf, variables, pipeline trigger on envs/prod/**
```

In zen-infra we use separate directories. A change to `envs/dev/main.tf` only triggers the dev pipeline — it never touches qa or prod state. Each environment also has different EKS node sizes, RDS instance types, and min/max scaling defined independently.

**Rule of thumb:** use workspaces for short-lived feature environments. Use separate directories for long-lived environments (dev, qa, prod).

---

### Q22. How do you design a reusable module? How do you pass different configs per environment? 🏗️

Good module design means no hardcoded values — everything comes from variables, and the module outputs everything callers might need.

In zen-infra the VPC module:

```hcl
# modules/vpc/variables.tf
variable "project" { type = string }
variable "env"     { type = string }
variable "vpc_cidr" { type = string }
variable "public_subnet_cidrs"      { type = list(string) }
variable "private_eks_subnet_cidrs" { type = list(string) }
variable "private_rds_subnet_cidrs" { type = list(string) }

# modules/vpc/outputs.tf
output "vpc_id"                  { value = aws_vpc.main.id }
output "private_eks_subnet_ids"  { value = aws_subnet.private_eks[*].id }
output "private_rds_subnet_ids"  { value = aws_subnet.private_rds[*].id }
```

Each environment passes its own values:

```hcl
# dev
module "vpc" {
  source                   = "../../modules/vpc"
  env                      = "dev"
  vpc_cidr                 = "10.0.0.0/16"
  private_eks_subnet_cidrs = ["10.0.3.0/24", "10.0.4.0/24"]
}

# prod — same module, different sizing
module "vpc" {
  source                   = "../../modules/vpc"
  env                      = "prod"
  vpc_cidr                 = "10.2.0.0/16"
  private_eks_subnet_cidrs = ["10.2.3.0/24", "10.2.4.0/24"]
}
```

Key design rule: modules should never know which environment they are running in — that is always an input. Modules should output everything, even things you do not need yet.

---

### Q23. What is -target (partial apply) and why is it risky?

`-target` tells Terraform to plan or apply only a specific resource, ignoring everything else.

```bash
# Only apply changes to the EKS node group
terraform apply -target=module.eks.aws_eks_node_group.main
```

It sounds useful in emergencies but carries real risks:

- **State drift** — if resource A depends on resource B and you only apply A, state may not reflect reality
- **Skipped dependency checks** — Terraform bypasses its own dependency graph for untargeted resources
- **Creates a bad habit** — teams start using `-target` regularly instead of fixing root causes

Legitimate uses: importing a single resource, debugging a specific resource during development. Never as a routine operation in production. If you find yourself reaching for `-target` regularly, the infrastructure should probably be split into smaller state files.

---

### Q24. How do you handle large infrastructure with 100+ resources?

Three main strategies:

**1. Split state by layer:**

```
state/
├── network/     ← VPC, subnets, gateways (changes rarely)
├── compute/     ← EKS, node groups (changes occasionally)
└── app/         ← ECR, Secrets Manager (changes frequently)
```

Lower layers export outputs consumed by upper layers via `terraform_remote_state` data source. Changes to the app layer never risk touching network resources.

**2. Use modules aggressively** — group related resources so a `plan` shows meaningful logical changes, not 100 individual resource diffs.

**3. Speed up plans:**

```bash
# Skip refresh when you know nothing drifted externally
terraform plan -refresh=false

# Increase parallelism for large applies
terraform apply -parallelism=20
```

In zen-infra we keep each environment in one state but split across 6 modules — plans are fast because Terraform parallelises modules that have no dependencies on each other (ECR, IAM, and Secrets Manager all start simultaneously).

---

## Section 4 — CI/CD & Team

### Q25. How do you run Terraform safely in GitHub Actions? 🏗️

The key is a strict job sequence with gates at the right points. In zen-infra:

```yaml
jobs:
  plan:
    runs-on: ubuntu-latest
    steps:
      - run: terraform fmt -check      # fail fast on formatting
      - run: terraform init            # connect to S3 backend, download providers
      - run: terraform validate        # syntax check before any API call
      - run: terraform plan -out=tfplan
      - uses: actions/upload-artifact@v4  # save plan binary for apply job
        with:
          name: tfplan
          path: envs/dev/tfplan

  apply:
    needs: plan
    if: github.ref == 'refs/heads/main' && github.event_name == 'push'
    environment: dev              # pauses here — requires manual approval
    steps:
      - uses: actions/download-artifact@v4
        with:
          name: tfplan
      - run: terraform apply tfplan   # apply the exact saved plan
```

Two critical details:

- **Save and reuse the plan** — uploading `tfplan` and downloading it in the apply job ensures apply executes exactly what was reviewed. Without this, a re-plan between approval and apply could pick up new unreviewed changes.
- **Apply only on `main`** — the `if` condition blocks apply from running on any PR or feature branch.

---

### Q26. How do you handle manual approval for apply and destroy? 🏗️

In GitHub Actions, a **GitHub Environment** with required reviewers acts as the approval gate:

1. Go to repo Settings → Environments → Create environment (`dev`, `qa`, `prod`)
2. Add required reviewers
3. Reference the environment in the job:

```yaml
apply:
  environment: dev   # pipeline pauses here until a reviewer approves in GitHub UI
```

For **destroy**, zen-infra adds a second layer — a typed confirmation input:

```yaml
workflow_dispatch:
  inputs:
    action:
      type: choice
      options: [plan, apply, destroy]
    confirm_destroy:
      description: 'Type "destroy" to confirm'

destroy:
  if: |
    github.event.inputs.action == 'destroy' &&
    github.event.inputs.confirm_destroy == 'destroy'
  environment: dev   # approval gate applies here too
```

Two-factor protection: you must select `destroy` AND type the word `destroy` AND get human approval. One wrong click is never enough to tear down infrastructure.

---

### Q27. How do you handle Terraform in a team environment?

The problems you hit without structure: state conflicts, people applying from laptops, no visibility into what is running, secrets in committed tfvars files.

| Problem | Solution used in zen-infra |
|---|---|
| State conflicts | Remote S3 state with native locking |
| Parallel applies | Pipeline concurrency groups (`cancel-in-progress: false`) |
| Secrets in code | GitHub Secrets passed as `-var` at runtime |
| No change visibility | Plan output visible in pipeline logs on every PR |
| Unreviewed changes | Branch protection + PR required + apply only on `main` |
| Wrong environment | Separate state files + path-based triggers + approval gates |
| Provider drift | Dependabot opens PRs for provider updates weekly |

The cultural rule: **nobody runs `terraform apply` from their laptop in shared environments**. All applies go through the pipeline. Local Terraform is only for development in personal AWS sandbox accounts.

---

### Q28. How do you manage multiple AWS accounts?

Each environment or team gets its own AWS account — this is the AWS recommended pattern (AWS Organizations). Benefits: blast radius isolation, separate billing, no accidental cross-environment resource access.

Terraform handles this through provider role assumption:

```hcl
# Assume role into a specific account
provider "aws" {
  region = "us-east-1"
  assume_role {
    role_arn = "arn:aws:iam::PROD_ACCOUNT_ID:role/TerraformRole"
  }
}

# Multiple accounts with provider aliases
provider "aws" {
  alias  = "dev"
  assume_role { role_arn = "arn:aws:iam::DEV_ACCOUNT:role/TerraformRole" }
}

provider "aws" {
  alias  = "prod"
  assume_role { role_arn = "arn:aws:iam::PROD_ACCOUNT:role/TerraformRole" }
}
```

In CI/CD the pipeline uses OIDC to assume a role per environment — no static credentials, and each role only has permissions within its own account.

---

### Q29. How do you deploy Kubernetes resources using Terraform? 🏗️

Terraform has a `kubernetes` provider that manages K8s resources alongside the cluster.

```hcl
# First provision the EKS cluster (aws provider)
module "eks" {
  source = "../../modules/eks"
  ...
}

# Configure the kubernetes provider using EKS cluster outputs
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_ca_certificate)
  token                  = data.aws_eks_cluster_auth.main.token
}

# Deploy Kubernetes resources
resource "kubernetes_namespace" "app" {
  metadata { name = "pharma-app" }
}
```

In zen-infra the EKS module provisions the cluster and OIDC provider. The OIDC provider enables IRSA (IAM Roles for Service Accounts) so pods can assume IAM roles without node-level credentials.

**Word of caution:** Terraform is not the best tool for deploying applications into Kubernetes. It is great for cluster-level resources — namespaces, RBAC, storage classes. For application deployments, Helm or ArgoCD are better suited — they understand rollout strategies, health checks, and rollbacks in ways Terraform does not.

---

## Section 5 — Scenario-Based

### Q30. Two engineers run terraform apply at the same time. What happens? How do you prevent it? 🏗️

If state locking is configured: the second apply fails immediately with a clear error — who holds the lock and since when. The second engineer waits and retries.

If locking is NOT configured: both applies run simultaneously, one overwrites the other's state, and resources end up in an inconsistent state. This is exactly why zen-infra enforces remote state with locking AND uses pipeline concurrency groups:

```yaml
concurrency:
  group: terraform-${{ github.ref }}
  cancel-in-progress: false   # wait, never cancel — cancelling mid-apply corrupts state
```

`cancel-in-progress: false` is important. Cancelling a running apply mid-way can leave resources partially created and state broken. The second run waits in the queue instead.

---

### Q31. Someone manually deletes an AWS resource that Terraform created. What happens on the next plan? How do you handle drift? 🏗️

Terraform will show a plan to recreate it. State says it exists. AWS says it does not. Terraform resolves that gap by creating a new one.

```
# Plan output after manual deletion
module.rds.aws_db_instance.main must be replaced
  Plan: 1 to add, 0 to change, 0 to destroy.
```

**Handling drift properly:**

```bash
# See what drifted without applying anything
terraform apply -refresh-only

# Accept the drift — resource is gone, remove it from state too
terraform state rm module.rds.aws_db_instance.main

# Recreate it — let Terraform fix the drift
terraform apply
```

In practice, frequent drift usually means someone is making changes manually that should go through Terraform. That is a process problem, not a Terraform problem. Branch protection and a team agreement of "no manual AWS console changes to managed resources" solve the root cause.

---

### Q32. You need to pass a DB password securely. Would you store it in .tfvars? What is a better approach? 🏗️

Never in a file committed to git. Even a private repo can be leaked and git history is permanent.

**Better approaches in order of preference:**

**1. GitHub Secrets passed at runtime** — what zen-infra does:
```yaml
terraform plan -var="db_password=${{ secrets.DEV_DB_PASSWORD }}"
```

**2. AWS Secrets Manager — application reads at runtime:**
```hcl
data "aws_secretsmanager_secret_version" "db" {
  secret_id = "/pharma/dev/db-credentials"
}
```

**3. Environment variable — Terraform picks up `TF_VAR_<name>` automatically:**
```bash
export TF_VAR_db_password="mysecret"
terraform plan
```

In zen-infra, DB credentials come from GitHub Secrets at pipeline runtime and are also stored in AWS Secrets Manager for the application to read at runtime. The password is never on disk, never in a file, never visible in plan output (variables marked `sensitive = true` are redacted).

---

### Q33. terraform apply failed in the middle. What happens to your resources? How do you recover?

Resources successfully created before the failure exist in AWS and are recorded in state. Resources that failed or had not started yet are not in state.

Re-running `apply` is safe — Terraform skips what already exists and retries only what failed. It will not duplicate anything already tracked in state. This is Terraform's idempotency guarantee.

```bash
# Just re-run — Terraform figures out what is left to do
terraform apply tfplan

# If the saved plan has expired or things changed, re-plan first
terraform plan -out=tfplan
terraform apply tfplan
```

The tricky case is a partial resource — for example, an EKS cluster created but its node group failed. State has the cluster, not the node group. The next apply creates only the missing node group. No manual cleanup needed.

---

### Q34. A small config change is causing a resource to be destroyed and recreated. Why? How do you avoid it?

Some resource attributes are marked as **"forces new resource"** in the provider — changing them requires destroying and creating a new resource because AWS cannot update them in-place.

```
# Terraform tells you explicitly in the plan output
~ resource "aws_db_instance" "main" {
    ~ identifier = "pharma-dev-db" -> "pharma-dev-postgres"   # forces replacement
  }
  Plan: 1 to add, 0 to change, 1 to destroy.
```

Common examples that force replacement: RDS `identifier`, `engine`, `db_name`; EKS cluster `name`; EC2 `ami`.

**Options:**

1. **Do not change that attribute** — check the provider docs before making the change
2. **`create_before_destroy`** — if recreation is unavoidable, minimise downtime:

```hcl
lifecycle {
  create_before_destroy = true
}
```

3. **`ignore_changes`** — if the attribute is managed outside Terraform:

```hcl
lifecycle {
  ignore_changes = [engine_version]
}
```

---

### Q35. Existing infrastructure was created manually in AWS. How do you bring it under Terraform?

This is common when adopting Terraform on an existing project. The process:

1. Write Terraform config that matches the existing resource
2. Import the resource into state using its AWS ID
3. Run `plan` — zero changes means your config matches reality
4. Fix any discrepancies until plan is clean

```bash
# Import existing VPC
terraform import module.vpc.aws_vpc.main vpc-0abc1234def567890

# Confirm no changes
terraform plan
# Plan: 0 to add, 0 to change, 0 to destroy.
```

For bulk imports, use Terraform 1.5+ `import` blocks:

```hcl
import {
  to = aws_vpc.main
  id = "vpc-0abc1234def567890"
}
```

Run `terraform plan -generate-config-out=generated.tf` and Terraform scaffolds the config. Still needs review but saves hours of manual writing.

The hardest part is not the import command — it is writing Terraform config that exactly matches what AWS has. One wrong attribute triggers a change on the next apply.

---

### Q36. You are adding a new environment. How do you do it without touching existing environments? 🏗️

```bash
# 1. Copy the dev structure as a starting point
cp -r envs/dev envs/staging

# 2. Update backend.tf — unique state key
#    key = "envs/staging/terraform.tfstate"

# 3. Adjust sizing in main.tf for staging (node counts, instance types, etc.)

# 4. Create a GitHub Environment called "staging" with required reviewers

# 5. Add staging path to pipeline triggers
#    paths: ['envs/staging/**', 'modules/**']

# 6. Init, validate, and plan
cd envs/staging
terraform init
terraform validate
terraform plan
```

In zen-infra, all three environments share the same modules. Adding staging means creating a new directory and updating two files. The modules themselves do not change at all, and existing dev/qa/prod pipelines are completely unaffected.

---

### Q37. Your pipeline keeps timing out waiting for an EKS cluster. How do you fix it?

EKS clusters take 15-20 minutes to provision. Terraform has default resource-level timeouts and the CI runner has a job-level timeout.

```hcl
resource "aws_eks_cluster" "main" {
  ...
  timeouts {
    create = "30m"
    delete = "20m"
  }
}
```

Also check your pipeline job timeout — GitHub Actions defaults to 6 hours but some configs set it lower.

Beyond timeouts, this can also be a missing `depends_on`. If Terraform starts configuring the cluster before the IAM role policy attachment is propagated, the cluster creation will fail. IAM changes in AWS can take 10-30 seconds to propagate globally. Adding an explicit `depends_on` to the IAM attachments usually fixes this.

---

### Q38. You changed one value but the plan shows the resource being recreated. How do you investigate?

```bash
# Run plan with full detail
terraform plan -out=tfplan

# Inspect the plan in detail
terraform show tfplan
```

Look for the `# forces replacement` annotation in the plan output — Terraform explicitly marks which attribute is causing the recreation.

If you did not intentionally change that attribute, check:

1. **Provider upgrade** — a new provider version may have changed how an attribute is handled
2. **Drift** — someone changed the resource in AWS and the state no longer matches
3. **Computed attribute** — some attributes are set by AWS at creation and Terraform is detecting a difference

```bash
# Run a refresh-only plan to see if drift is the cause
terraform apply -refresh-only

# Check what changed between provider versions
terraform providers lock -upgrade   # updates .terraform.lock.hcl
```

If the recreation is harmless and expected (e.g. a tag change on an EKS node group causes node replacement), use `lifecycle { ignore_changes = [tags] }` to suppress it. If it is unexpected, dig into the provider changelog before applying.

---

### Q39. Tell me about a real infrastructure problem you solved with Terraform. 🏗️

Our Terraform state was accidentally deleted but the ECR repositories still existed in AWS — AWS blocks deletion of non-empty repos and they all contained container images. When we re-ran `terraform apply`, it failed with `RepositoryAlreadyExistsException` for every repo.

Manually deleting the repos was not an option — that would have destroyed all the container images. Instead I used declarative `import` blocks (introduced in Terraform 1.5) to adopt the existing repos back into state without recreating them:

```hcl
import {
  to = module.ecr.aws_ecr_repository.main["api-gateway"]
  id = "api-gateway"
}

import {
  to = module.ecr.aws_ecr_repository.main["auth-service"]
  id = "auth-service"
}
# ... one block per repo
```

The import ID for an ECR repository is simply the repository name. On the next `terraform apply`, Terraform read the existing repos from AWS and wrote them into state — no recreation, no downtime, no lost images.

This is why declarative import blocks are better than the CLI `terraform import` command: the imports are in a `.tf` file, reviewable in a PR, and idempotent — safe to leave in place after the first apply.

---

### Q40. Your Terraform code works in dev but fails in prod. How do you debug it? 🏗️

Systematic approach:

**1. Compare environment configs:**
```bash
diff envs/dev/main.tf envs/prod/main.tf
```
Check for differences in instance types, subnet CIDRs, scaling values, or any hardcoded values that are valid in dev but not prod.

**2. Read the exact error** — is it a permissions error, a naming conflict, a quota limit, or a resource that already exists? Each has a different fix.

**3. Check IAM permissions** — the CI role in prod may have different permissions than dev:
```bash
TF_LOG=DEBUG terraform plan 2>&1 | grep -i "denied\|not authorized"
```

**4. Run plan locally against prod:**
```bash
cd envs/prod
terraform plan -var="db_password=dummy"
```
The plan output shows exactly what Terraform sees vs what it wants — without applying anything.

**5. Check provider versions** — if `terraform init` was run at different times, dev and prod might use different provider patch versions. Pin versions explicitly:
```hcl
version = "~> 5.50"
```

Most common root causes in practice:
- IAM role missing a permission that the dev role has
- Prod account hitting a service quota that dev does not
- Hard-coded values (AMI IDs, subnet IDs) valid in dev but not prod
- A resource naming conflict because something already exists in prod from a previous manual setup

In zen-infra, running into this was actually how we caught that the prod pipeline IAM role was missing `ecr:DescribeRepositories` — dev worked fine because the dev role had broader permissions during early setup.

---

*Reference implementation: [zen-infra](../README.md) — a production-grade AWS infrastructure using Terraform, EKS, RDS, ECR, and GitHub Actions CI/CD.*
