# Zen Pharma — DevOps Interview Preparation

Covers two areas:
- **Part 1 — CI/CD, GitOps & DevSecOps** (12 topic sections, ~50 questions)
- **Part 2 — Terraform & Infrastructure** (40 questions)

All answers are grounded in the actual architecture of this project. Questions compiled from real interviews at Google, Amazon, Microsoft, Netflix, Uber, Meta, JPMorgan, Goldman Sachs, and equivalent-tier companies.

---

# Part 1 — CI/CD, GitOps & DevSecOps


---

## Table of Contents

1. [GitOps and ArgoCD](#1-gitops-and-argocd)
2. [GitHub Actions and CI Pipeline](#2-github-actions-and-ci-pipeline)
3. [Branching Strategy](#3-branching-strategy)
4. [Docker and Container Security](#4-docker-and-container-security)
5. [SAST — CodeQL and Semgrep](#5-sast--codeql-and-semgrep)
6. [Dependency and Image Scanning](#6-dependency-and-image-scanning)
7. [Supply Chain Security — Cosign and Sigstore](#7-supply-chain-security--cosign-and-sigstore)
8. [AWS OIDC and IAM](#8-aws-oidc-and-iam)
9. [Kubernetes and Helm](#9-kubernetes-and-helm)
10. [Incident and Rollback Scenarios](#10-incident-and-rollback-scenarios)
11. [DevSecOps Philosophy and Shift-Left](#11-devsecops-philosophy-and-shift-left)
12. [Scenario-Based and Design Questions](#12-scenario-based-and-design-questions)

---

## 1. GitOps and ArgoCD

---

**Q: What is GitOps and how does it differ from traditional CI/CD?**

- **What is being tested:** Whether you understand GitOps as a pull-based declarative model — not just "we use Git."
- **Strong answer:** In traditional CI/CD, the pipeline pushes changes to the cluster using `kubectl apply` or Helm commands. Once the pipeline finishes, there is no ongoing guarantee that the cluster stays in the desired state — someone could `kubectl edit` a deployment manually and drift from what CI deployed. GitOps inverts this. Git is the single source of truth for desired state. ArgoCD runs inside the cluster and continuously pulls from Git, comparing desired state against actual cluster state. Any drift is detected and self-healed automatically. Every change to the cluster is a Git commit — auditable, reversible, and author-attributed.
- **Project context:** In our project, GitHub Actions never runs `kubectl` directly. It only commits to `chandika-s/zen-gitops`. ArgoCD watches that repo and syncs the cluster. If someone manually changes a deployment in Kubernetes, ArgoCD detects the drift and reverts it to what's in Git.

---

**Q: Explain ArgoCD's core components and how they work together.**

- **What is being tested:** Internal architecture knowledge, not just "ArgoCD deploys things."
- **Strong answer:** ArgoCD has four main components. The **API Server** exposes the gRPC/REST interface used by the UI and CLI. The **Repository Server** clones Git repos and renders Helm/Kustomize manifests into raw Kubernetes manifests. The **Application Controller** is a Kubernetes controller that runs the reconciliation loop — it continuously compares the live cluster state against the rendered desired state and marks apps as Synced, OutOfSync, or Degraded. **Redis** caches rendered manifests and cluster state to reduce API server load. ArgoCD uses Kubernetes CRDs — `Application`, `AppProject`, `ApplicationSet` — so its own state is stored in etcd, making it self-healing and HA-capable.

---

**Q: What is the difference between ArgoCD auto-sync and manual sync? When do you use each?**

- **What is being tested:** Whether you understand the operational implications of auto vs. manual sync.
- **Strong answer:** Auto-sync means ArgoCD applies changes to the cluster as soon as it detects a diff between Git and the cluster — typically within the poll interval (default 3 minutes). Manual sync means ArgoCD detects the diff but waits for a human to click Sync in the UI or run `argocd app sync`. Use auto-sync for lower environments where fast feedback is the goal. Use manual sync for production — production changes should happen at a planned maintenance window with an engineer watching the rollout, not automatically at 2am because someone merged a PR.
- **Project context:** DEV uses auto-sync (`pharma-dev`), QA uses auto-sync (`pharma-qa`) because the gate is the PR merge in zen-gitops — once the QA team merges the PR they want it deployed immediately. PROD uses manual sync (`pharma-prod`) — after the PROD PR merges, ArgoCD shows OutOfSync, and an engineer triggers sync at the maintenance window.

---

**Q: How do you handle a rollback in a GitOps model?**

- **What is being tested:** Understanding that rollback is a git revert, not a kubectl rollout undo.
- **Strong answer:** In GitOps, a rollback is simply reverting the Git commit that updated the image tag in the values file. You `git revert` the promotion commit in zen-gitops, merge it, and ArgoCD syncs the cluster back to the previous image. This is safer than `kubectl rollout undo` because it goes through the same reconciliation loop as a forward deployment, and the rollback is also captured in Git history with an author and timestamp. You can also roll back to any arbitrary previous version by changing the image tag to any previously-pushed SHA.

---

**Q: What is ArgoCD ApplicationSet and when would you use it?**

- **What is being tested:** Whether you know ArgoCD beyond the basics.
- **Strong answer:** ApplicationSet is an ArgoCD CRD that generates multiple Application resources from a template, using generators like List, Cluster, Git directory, or Pull Request generators. Instead of maintaining 7 separate ArgoCD Application YAMLs for 7 services, you write one ApplicationSet with a list generator and it creates and manages all 7 automatically. It is particularly useful in a monorepo pattern where each subdirectory is a service — the Git directory generator discovers them automatically.

---

**Q: How does ArgoCD handle secrets? Can you store secrets in Git?**

- **What is being tested:** Security awareness around GitOps and secrets.
- **Strong answer:** You should never store plain secrets in Git, even in a private repo. ArgoCD integrates with external secrets managers. The common patterns are: **Sealed Secrets** (Bitnami) — secrets are encrypted with a cluster-specific key and the encrypted blob is safe to commit; **External Secrets Operator** — ArgoCD syncs a CRD that tells the operator to fetch the secret from AWS Secrets Manager or HashiCorp Vault; **Vault Agent Injector** — secrets are injected into pods as environment variables or files at runtime without ever touching Git.

---

## 2. GitHub Actions and CI Pipeline

---

**Q: What is a reusable workflow in GitHub Actions and why would you use it?**

- **What is being tested:** DRY principles in CI, `workflow_call` understanding.
- **Strong answer:** A reusable workflow uses `on: workflow_call` and is called from other workflows using `uses:` with a file path. It accepts inputs and secrets, and can return outputs. The benefit is that complex logic — build, scan, push — is defined once and called by each service workflow. Changes to the pipeline (e.g. upgrading Trivy version) are made in one place and automatically apply to all services. It also enforces consistency — every service goes through identical security gates with no accidental variation.
- **Project context:** `_java-build.yml` and `_node-build.yml` contain the full 8-stage pipeline. Each `ci-<service>.yml` is ~10 lines — it just calls the reusable workflow with the service-specific inputs.

---

**Q: What is the difference between `workflow_call`, `workflow_dispatch`, and `workflow_run`?**

- **What is being tested:** Depth of GitHub Actions knowledge.
- **Strong answer:** `workflow_call` makes a workflow reusable — it can only be triggered by another workflow using `uses:`. `workflow_dispatch` adds a manual trigger with optional input parameters — shows up as a "Run workflow" button in the GitHub Actions UI. `workflow_run` triggers a workflow when another named workflow completes — useful for chaining workflows that are in separate files (e.g. run integration tests after the build workflow completes). The key difference from `needs:` is that `workflow_run` works across separate workflow files.
- **Project context:** `promote-prod.yml` uses `workflow_dispatch` with a service dropdown. The per-service `ci-*.yml` files use `workflow_call` to call `_java-build.yml`.

---

**Q: How do you pass secrets to a reusable workflow?**

- **What is being tested:** Security mechanics of reusable workflows.
- **Strong answer:** There are two ways. The explicit way declares each secret in the `on.workflow_call.secrets` block and the caller passes them individually. The simpler way is `secrets: inherit` in the caller — this passes all secrets from the caller's context to the called workflow automatically. `secrets: inherit` is convenient but less explicit about what secrets the reusable workflow actually needs.
- **Project context:** All `ci-*.yml` files use `secrets: inherit` when calling `_java-build.yml` — so `AWS_ACCOUNT_ID`, `GITOPS_TOKEN`, and `SEMGREP_APP_TOKEN` are all inherited automatically.

---

**Q: What are path filters in GitHub Actions and why are they important in a monorepo?**

- **What is being tested:** Monorepo CI efficiency.
- **Strong answer:** Path filters under `on.push.paths` restrict a workflow to only trigger when files matching the pattern have changed. In a monorepo without path filters, every push triggers all workflows — a change to `notification-service/` would rebuild all 7 services unnecessarily. With path filters, only the affected service's workflow triggers. Most monorepo CI setups also include the workflow file itself in the paths so that CI configuration changes are validated.

---

**Q: What is GitHub OIDC and how does it work with AWS?**

- **What is being tested:** Modern secrets-free authentication understanding.
- **Strong answer:** GitHub Actions supports OpenID Connect. When a workflow runs, GitHub generates a short-lived OIDC token signed by GitHub's identity provider. This token contains claims about the repository, branch, and workflow. AWS IAM supports OIDC federation — you configure an IAM role with a trust policy that allows GitHub's OIDC provider. When the workflow runs `aws-actions/configure-aws-credentials`, it exchanges the GitHub OIDC token for short-lived AWS credentials scoped to that role. No static access keys are stored anywhere. The credentials expire when the workflow run ends.

---

**Q: How do you prevent a workflow from running on certain branches or events?**

- **What is being tested:** Workflow control flow knowledge.
- **Strong answer:** Multiple approaches: (1) `on.push.branches` / `on.pull_request.branches` restrict triggers to specific branches, (2) `on.push.paths-ignore` excludes certain file paths, (3) job-level `if:` conditions evaluate expressions like `github.ref == 'refs/heads/develop'`, (4) `environment:` with Required Reviewers blocks a job until a human approves. The right choice depends on whether you want to prevent the workflow from starting at all (branch/path filters) or pause at a specific job (environment gate).

---

**Q: What is a GitHub Environment and how does it enforce deployment gates?**

- **What is being tested:** GitHub's built-in deployment protection mechanisms.
- **Strong answer:** A GitHub Environment is a named deployment target (`dev`, `qa`, `prod`) configured in repo Settings. You can add Required Reviewers — the workflow pauses at any job referencing that environment until a reviewer approves it in the GitHub UI. You can also add wait timers, branch restrictions (only `main` can deploy to `prod`), and deployment history. The key thing is the gate happens at the job level — earlier jobs run, and the gated job waits for approval. This is how you implement a human sign-off without splitting into multiple separate workflows.
- **Project context:** Our `deploy-dev` job uses `environment: dev` (no gate). Our `promote-prod.yml` uses `environment: prod` with Required Reviewers — the workflow cannot even start until a Release Manager approves.

---

## 3. Branching Strategy

---

**Q: Walk me through your branching strategy from a feature to production.**

- **What is being tested:** End-to-end understanding of Gitflow / trunk-based hybrid.
- **Strong answer:** Feature development starts on a branch cut from `develop` — named `feat/JIRA-101-description`. The developer pushes to their branch, gets fast CI feedback (SAST, tests, OWASP) in ~5 minutes. When ready, they open a PR targeting `develop`. The same CI runs on the PR. After code review and approval, it merges to `develop`. At sprint end, a release branch is cut from `develop` — `release/1.2.0`. Develop is now open for the next sprint. The release branch goes through QA testing. Any bugs found are fixed on branches off `release/1.2.0` and merged back. Once QA signs off, PROD promotion is triggered. After PROD is healthy, `release/1.2.0` is merged to `main` (tagged `v1.2.0`) and back-merged to `develop` to carry forward any hotfixes. The release branch is then deleted.

---

**Q: Why do you back-merge the release branch into develop?**

- **What is being tested:** Awareness of the most common Gitflow mistake — losing hotfixes.
- **Strong answer:** Any bug fixes made directly on the release branch during QA must flow back to develop — otherwise the next sprint starts with develop not containing those fixes and they get lost in the next release. The back-merge ensures develop always contains everything that has ever been released to PROD.

---

**Q: What is trunk-based development and how does it differ from Gitflow?**

- **What is being tested:** Awareness of the alternative model, common at Netflix, Google, Uber.
- **Strong answer:** In trunk-based development, all developers commit frequently (multiple times a day) to a single branch — `main` or `trunk`. Feature branches are very short-lived (hours, not days). Feature flags hide incomplete work from users. There are no long-lived `develop` or `release` branches. CI runs on every commit to trunk. This model reduces merge hell and integration pain but requires strong feature flag discipline and very high test coverage. Gitflow suits teams with scheduled releases and formal QA phases. Trunk-based suits teams doing continuous deployment.

---

**Q: How do you handle a hotfix in production without disrupting the current sprint?**

- **What is being tested:** Practical Gitflow knowledge.
- **Strong answer:** Cut a hotfix branch directly from `main` (which reflects current PROD), not from develop (which may have unreleased sprint work). Fix the bug on the hotfix branch, get it reviewed, and merge it to `main`. Tag it as `v1.1.1`. Then back-merge `main` into `develop` so the fix is not lost in the next release. Do not merge from `develop` into `main` for a hotfix — `develop` may contain half-built features you don't want in production.

---

## 4. Docker and Container Security

---

**Q: What is a multi-stage Docker build and why does it matter for security?**

- **What is being tested:** Container image hygiene.
- **Strong answer:** A multi-stage build uses multiple `FROM` instructions. Early stages contain build tools (Maven, JDK SDK, npm). The final stage copies only the compiled artifact from the build stage — no Maven, no JDK, no source code, no node_modules dev dependencies make it into the production image. This reduces image size (smaller attack surface), removes tools that have no business in a runtime container (Maven could be used to download arbitrary JARs if compromised), and reduces the number of CVEs Trivy finds because fewer packages are present.

---

**Q: Why should containers never run as root?**

- **What is being tested:** Container escape and privilege escalation awareness.
- **Strong answer:** If a container runs as root (UID 0) and a container escape vulnerability is exploited, the attacker gets root on the host node. From there they can read secrets mounted to other pods, modify host-level configurations, or pivot to the Kubernetes control plane. Running as UID 1000 limits the blast radius — the attacker gets the privileges of a non-privileged user. Kubernetes PodSecurityAdmission and tools like Kyverno can enforce `runAsNonRoot: true` at admission time, rejecting any pod spec that attempts to run as root.
- **Project context:** Our Dockerfiles use `--build-arg UID=1000 --build-arg GID=1000` and set `USER 1000` in the final stage.

---

**Q: What is the difference between a Docker image tag and a digest?**

- **What is being tested:** Image immutability understanding.
- **Strong answer:** A tag (e.g. `myimage:sha-abc1234`) is a mutable pointer — it can be reassigned to point to a different image by pushing a new image with the same tag. A digest (e.g. `sha256:abc123...`) is the cryptographic SHA256 hash of the image manifest — it is content-addressable and immutable. The same digest always refers to the exact same bytes. For security-sensitive deployments, you reference images by digest, not by tag, in production manifests. Cosign signs the digest, not the tag, for this reason.

---

**Q: How do you reduce the size of a Docker image?**

- **What is being tested:** Practical Docker knowledge.
- **Strong answer:** (1) Multi-stage builds — only copy what the runtime needs, (2) Use minimal base images — `eclipse-temurin:17-jre-alpine` instead of the full JDK image, (3) Combine `RUN` instructions to reduce layers, (4) Use `.dockerignore` to exclude source files, test reports, and build artifacts from the build context, (5) Remove package manager caches in the same `RUN` instruction that installs them (`apt-get clean && rm -rf /var/lib/apt/lists/*`), (6) Don't install debugging tools (curl, wget, bash) in production images.

---

## 5. SAST — CodeQL and Semgrep

---

**Q: What is SAST and at what stage of the pipeline should it run?**

- **What is being tested:** Shift-left security understanding.
- **Strong answer:** Static Application Security Testing analyses source code without executing it, looking for vulnerability patterns. It should run as early as possible — ideally on every push to a feature branch, not just before merging to main. Finding a SQL injection on a feature branch takes minutes to fix. Finding it after merging to develop, building an image, and deploying to DEV takes hours. The cost of fixing a security issue grows exponentially the later it is found in the SDLC.

---

**Q: What is the difference between CodeQL and Semgrep? Why would you run both?**

- **What is being tested:** Tool depth and understanding of their different approaches.
- **Strong answer:** CodeQL performs deep semantic analysis. It instruments the compilation to build a full call graph and data flow model, then queries it using a custom query language (QL). It excels at finding complex multi-step vulnerabilities — SQL injection where user input flows through three service layers before reaching a query, path traversal assembled across multiple methods. Semgrep uses pattern matching on the AST — it is faster but cannot track data flow across method boundaries. Semgrep excels at framework-specific misconfigurations: Spring Boot CSRF disabled, actuator endpoints without authentication, missing `@PreAuthorize` annotations, CORS wildcards. Running both gives you deep data flow analysis from CodeQL and framework-specific pattern coverage from Semgrep with minimal overlap.

---

**Q: CodeQL instruments the build. What does that mean and why does it matter?**

- **What is being tested:** Deep CodeQL knowledge.
- **Strong answer:** CodeQL uses a technique called build tracing — it intercepts calls to the compiler (`javac`, `kotlinc`) during the actual `mvn compile` phase to extract type information, method signatures, and call relationships that are only available during compilation. This is why `codeql-action/init` must run before Maven — if you initialise CodeQL after Maven has already compiled the code, the tracer was never in place and CodeQL either produces a weaker analysis or fails with an empty database error. This instrumentation is what enables CodeQL to track data flow across file and class boundaries.

---

**Q: What are SARIF files and why does your pipeline upload them to GitHub?**

- **What is being tested:** Security tooling integration knowledge.
- **Strong answer:** SARIF (Static Analysis Results Interchange Format) is a JSON-based standard for representing static analysis results — findings, severity, file location, and remediation guidance. GitHub's Code Scanning feature ingests SARIF files and displays findings in the Security tab, aggregated across all tools and services. This means security engineers get a single dashboard showing CodeQL, Semgrep, and Trivy findings across all 7 services without reading raw pipeline logs. Findings can be triaged, dismissed with a reason, and tracked over time.

---

## 6. Dependency and Image Scanning

---

**Q: What is SCA and how is it different from SAST?**

- **What is being tested:** Knowing the distinction between code vulnerabilities and dependency vulnerabilities.
- **Strong answer:** SAST analyses code you wrote for security vulnerabilities in your logic. SCA (Software Composition Analysis) analyses the third-party libraries and frameworks you depend on for known CVEs published in vulnerability databases like the NVD. You could write perfectly secure code but depend on a version of Spring Boot with Log4Shell — SAST would not catch this because it's not in your code, but SCA would. OWASP Dependency Check and Snyk are SCA tools. Both SAST and SCA are needed.

---

**Q: What is CVSS and what score threshold makes sense for a build gate?**

- **What is being tested:** Security scoring knowledge and pragmatic thinking.
- **Strong answer:** CVSS (Common Vulnerability Scoring System) is a 0–10 numerical score representing the severity of a vulnerability. 0–3.9 is Low, 4.0–6.9 is Medium, 7.0–8.9 is High, 9.0–10 is Critical. Most security frameworks (PCI-DSS, SOC 2, HIPAA) require remediating High and Critical findings. Setting the build gate at CVSS ≥ 7.0 (High) is a common industry standard — it blocks the build when there is something genuinely exploitable and actionable. Setting it at 9.0 only catches the very worst cases and misses a large class of exploitable vulnerabilities. Setting it at 4.0 blocks too many builds on Medium findings that are often theoretical in your context.

---

**Q: What does `ignore-unfixed` mean in Trivy and why is it used?**

- **What is being tested:** Practical scanning operations knowledge.
- **Strong answer:** `ignore-unfixed: true` tells Trivy to report CVEs that have no available patched version but not to fail the build on them. If a CVE exists in a base OS package and the vendor has not yet released a fix, failing the build gives you no actionable path — you cannot update a package that has no update available. You would be permanently blocked. `ignore-unfixed` means the build only fails when a fix exists, i.e. there is something you can actually do. Unfixed CVEs still appear in the SARIF report for visibility and can be tracked separately.

---

**Q: What is the difference between OWASP Dependency Check and Trivy?**

- **What is being tested:** Understanding the different scanning surfaces.
- **Strong answer:** OWASP Dependency Check scans your declared source dependencies — what's listed in `pom.xml` or `package.json` — against the NVD. It runs before Docker build and catches vulnerable libraries in your application code. Trivy scans the built container image — OS-level packages installed by the Dockerfile base image, the JRE runtime, and all native libraries bundled inside the image. A vulnerable `libssl` in the Alpine base layer or a vulnerable `glibc` would only be caught by Trivy. A vulnerable Spring Boot version would be caught by both but OWASP Dep Check catches it earlier. Both are needed because they scan different surfaces.

---

## 7. Supply Chain Security — Cosign and Sigstore

---

**Q: What is supply chain security in the context of container images?**

- **What is being tested:** Whether you understand attacks beyond code vulnerabilities.
- **Strong answer:** Supply chain attacks target the build and distribution pipeline rather than the application code itself. A classic example: SolarWinds — attackers compromised the build system, not the source code. For containers, the threats include: a malicious dependency injected via a compromised package registry, a rogue image pushed directly to ECR bypassing CI, a developer manually pushing a backdoored image. Supply chain security controls include: signing images at build time (Cosign), verifying signatures at deploy time (Kyverno), generating SBOMs to know exactly what's in an image, and pinning dependencies to specific digest-verified versions.

---

**Q: How does Cosign keyless signing work?**

- **What is being tested:** Sigstore ecosystem knowledge.
- **Strong answer:** Keyless signing uses the workflow's OIDC identity instead of a long-lived private key. The process: (1) GitHub Actions generates an OIDC token that cryptographically identifies the workflow run and repository, (2) Cosign sends this token to Fulcio, a certificate authority in the Sigstore ecosystem, (3) Fulcio verifies the OIDC token and issues a short-lived X.509 certificate (valid for ~10 minutes) that encodes the workflow identity, (4) Cosign signs the image digest using this certificate, (5) the signature and certificate are written to the Rekor public transparency log — a tamper-evident, append-only ledger. There are no long-lived signing keys to manage, rotate, or leak.

---

**Q: What is Rekor and why is transparency important?**

- **What is being tested:** Depth of Sigstore knowledge.
- **Strong answer:** Rekor is a public, append-only transparency log maintained by the Sigstore project. Every Cosign signature is recorded in Rekor with a timestamped, tamper-evident log entry. Transparency means: anyone can verify that a signature was produced by a specific identity at a specific time. It also means that if a signing identity is compromised, the compromise is detectable — you can audit the log and see signatures that should not have been made. This is similar to Certificate Transparency logs used for TLS certificates.

---

**Q: How does Kyverno enforce image signing at the Kubernetes admission level?**

- **What is being tested:** End-to-end supply chain enforcement knowledge.
- **Strong answer:** Kyverno is a Kubernetes-native policy engine that runs as an admission webhook. When a pod is submitted to the API server, the request passes through Kyverno before being accepted. A Kyverno `ClusterPolicy` with `verifyImages` rules instructs Kyverno to check that the image has a valid Cosign signature in Rekor, signed by a specific identity (e.g. the GitHub Actions OIDC identity for your repo). If the signature is missing or invalid, Kyverno rejects the pod with an admission error — the pod never starts. This means even if someone pushes a rogue image directly to ECR, it cannot run in the cluster.

---

## 8. AWS OIDC and IAM

---

**Q: Why is OIDC-based authentication preferred over long-lived IAM access keys for CI/CD?**

- **What is being tested:** Cloud security fundamentals.
- **Strong answer:** Long-lived access keys have several problems: they don't expire, so a leaked key provides persistent access until manually rotated; they are often accidentally committed to source code or exposed in build logs; rotation is a manual operational burden; they need to be stored as secrets and managed. OIDC eliminates all of these: credentials are generated per workflow run, are scoped to that run only, expire when the run ends (~15 minutes), and there is nothing to store, rotate, or leak. The trust relationship is established cryptographically via the OIDC provider — the IAM role trusts JWT tokens signed by GitHub's OIDC provider for a specific repository and branch.

---

**Q: How do you scope an IAM role to be as least-privileged as possible for ECR push?**

- **What is being tested:** IAM security knowledge.
- **Strong answer:** The IAM role for CI should have exactly the permissions needed for ECR push and nothing else: `ecr:GetAuthorizationToken` (to get a login token), `ecr:BatchCheckLayerAvailability`, `ecr:PutImage`, `ecr:InitiateLayerUpload`, `ecr:UploadLayerPart`, `ecr:CompleteLayerUpload`. These should be scoped to specific ECR repository ARNs, not `*`. The trust policy should specify the exact GitHub repository and optionally the branch using the `sub` claim condition — e.g. `repo:myorg/myrepo:ref:refs/heads/develop` — so even if another repository somehow obtained a GitHub OIDC token, it could not assume this role.

---

**Q: What is the `sub` claim in a GitHub OIDC token and why does it matter?**

- **What is being tested:** OIDC token structure knowledge.
- **Strong answer:** The `sub` (subject) claim identifies the entity requesting the token. For GitHub Actions it takes the form `repo:<owner>/<repo>:ref:refs/heads/<branch>` or `repo:<owner>/<repo>:environment:<env>`. The IAM trust policy `StringEquals` condition on the `sub` claim is what prevents other repositories or branches from assuming the role. Without scoping the `sub` claim, any workflow in any repository could assume the role as long as it uses GitHub's OIDC provider. Always lock down the `sub` claim to the specific repo and optionally branch or environment.

---

## 9. Kubernetes and Helm

---

**Q: What is Helm and how does it relate to your GitOps values files?**

- **What is being tested:** Helm's role in the deployment pipeline.
- **Strong answer:** Helm is a Kubernetes package manager. A Helm chart is a parameterised template for Kubernetes manifests — Deployments, Services, ConfigMaps, Ingresses. Values files (`values-<service>.yaml`) provide the runtime parameters — image repository, image tag, replica count, resource limits, environment variables. ArgoCD renders the Helm chart with the values file to produce the final Kubernetes manifests and applies them to the cluster. In a GitOps model, you never run `helm upgrade` manually — ArgoCD does it when values files change.
- **Project context:** `zen-gitops` has a shared Helm chart (`helm-charts/`) and per-service values files in `envs/`. CI patches only `image.tag` in the values file. Everything else (replicas, resources, ingress) is managed separately in the values files by the platform team.

---

**Q: What happens in Kubernetes during a rolling update?**

- **What is being tested:** Kubernetes deployment mechanics.
- **Strong answer:** A rolling update gradually replaces old pods with new ones. Kubernetes creates a new ReplicaSet for the new version. It brings up new pods (controlled by `maxSurge` — how many extra pods can exist during the update) and only terminates old pods once new ones pass their readiness probe (controlled by `maxUnavailable` — how many old pods can be terminated before new ones are ready). This ensures zero downtime — at no point during the rollout are all pods unavailable. If the new pods fail their readiness probe, the rollout stalls and does not terminate old pods, limiting the blast radius.

---

**Q: What is a Kubernetes readiness probe vs a liveness probe?**

- **What is being tested:** Pod lifecycle knowledge.
- **Strong answer:** A readiness probe determines whether a pod is ready to receive traffic — if it fails, the pod is removed from the Service endpoint list but continues running. A liveness probe determines whether a pod is alive — if it fails, Kubernetes restarts the pod. Readiness is used to handle slow startup (Spring Boot apps can take 30–60 seconds to be ready) and temporary unreadiness (e.g. during a dependency outage). Liveness is used to detect deadlocks or hung processes that are still running but not functioning. You typically need both: readiness for traffic management, liveness for self-healing.

---

**Q: What is a Kyverno policy and how does it enforce security at the cluster level?**

- **What is being tested:** Kubernetes policy engine knowledge.
- **Strong answer:** Kyverno is a Kubernetes-native policy engine that runs as a validating and mutating admission webhook. It uses CRDs (`ClusterPolicy`, `Policy`) written in YAML to define rules. Validating policies reject resources that violate rules. Mutating policies automatically modify resources (e.g. add default labels or resource limits). Common policies: require non-root containers (`runAsNonRoot: true`), require resource limits on all containers, require image signature verification (Cosign), disallow `latest` image tags, require specific labels for cost allocation. Unlike OPA/Gatekeeper which uses Rego, Kyverno policies are YAML-native and easier to read.

---

## 10. Incident and Rollback Scenarios

---

**Q: A bad image was deployed to PROD and is causing errors. Walk me through the rollback.**

- **What is being tested:** Production incident response knowledge in a GitOps model.
- **Strong answer:** In our GitOps model: (1) Identify the previous good image tag from the git history of `envs/prod/values-<service>.yaml` in zen-gitops — `git log` shows every image tag that was ever deployed and when, (2) `git revert` the commit that updated to the bad image tag, or directly edit the values file to the last known good tag, (3) commit and push to zen-gitops, (4) trigger ArgoCD manual sync for `pharma-prod` — the cluster rolls back to the previous image via a standard rolling update. The rollback is itself a git commit with an author and timestamp — fully auditable. Alternatively, for speed, you can use `argocd app rollback <app> <history-id>` which reverts to a previous sync without a git commit, but this should be followed up with a git revert to keep Git as the source of truth.

---

**Q: A critical CVE is discovered in a library used by 5 of your 7 services. How do you handle it?**

- **What is being tested:** Incident management at scale.
- **Strong answer:** (1) Dependabot or OWASP Dependency Check will surface it automatically once the CVE is published to NVD, (2) Create a task to update the vulnerable library in each affected service's `pom.xml`, (3) For each service, a developer updates the dependency version and pushes — the full CI pipeline runs, OWASP Dep Check verifies the CVE is resolved, a new image is built and pushed to ECR, (4) Follow the normal DEV → QA → PROD promotion flow for each service, (5) If the CVE is critical and requires emergency patching, cut a hotfix branch from `release/current` for each affected service to bypass the sprint cycle. The key is that the normal promotion pipeline handles this — there is no separate "emergency deployment" path that bypasses security gates.

---

**Q: You notice that ArgoCD shows a service as OutOfSync but no one pushed any changes. What do you investigate?**

- **What is being tested:** GitOps drift detection understanding.
- **Strong answer:** OutOfSync without a git change means the cluster drifted from what Git declares. Common causes: (1) someone ran `kubectl edit` or `kubectl set image` manually — check Kubernetes audit logs, (2) a mutating webhook modified the resource after ArgoCD applied it — compare the live manifest to the rendered manifest in ArgoCD UI, (3) a Helm chart generates non-deterministic output (e.g. random annotations) — check if ArgoCD shows spurious diffs, (4) a node restarted and a DaemonSet pod was recreated with different state. The response is to investigate the cause, fix the root problem, and sync — not to just click Sync and move on, because the drift will recur.

---

**Q: Your CI pipeline is suddenly failing for all services on the OWASP Dependency Check step. What do you check?**

- **What is being tested:** Operational troubleshooting.
- **Strong answer:** First check if a new CVE was published to NVD that affects a shared dependency used across all services. If all services share a common Spring Boot parent version and a new High/Critical CVE was published for that version, all services will fail simultaneously. Check the OWASP HTML report artifacts to see which library and CVE triggered the failure. Second possibility: the NVD API rate limit was hit — OWASP Dependency Check downloads CVE data from NVD and NVD enforces rate limits; check if the NVD cache is configured correctly. Third: the NVD itself had an outage or API change — check the OWASP GitHub issues.

---

## 11. DevSecOps Philosophy and Shift-Left

---

**Q: What does "shift-left security" mean?**

- **What is being tested:** Core DevSecOps philosophy.
- **Strong answer:** In a traditional SDLC, security testing happened at the end — a penetration test or security review before release. Problems found at that stage are expensive to fix: the code is already written, deployed to staging, and reviewed. Shift-left means moving security checks earlier in the development process — ideally to the developer's own machine or at minimum to the first CI run on a feature branch. The earlier a security issue is found, the cheaper and faster it is to fix. A SAST finding on a feature branch takes minutes to fix. The same finding after merging to main, building an image, and deploying to staging takes hours. After reaching production, it may require a CVE disclosure, customer notification, and emergency hotfix.

---

**Q: What is an SBOM and why is it increasingly required?**

- **What is being tested:** Supply chain security awareness, compliance trends.
- **Strong answer:** An SBOM (Software Bill of Materials) is a machine-readable inventory of all components in a software artifact — every library, version, and license. It is the equivalent of an ingredient list for software. When a new CVE is disclosed (like Log4Shell), organisations with an SBOM can immediately query it to find which services are affected. Without one, they have to manually audit every service. US Executive Order 14028 (2021) mandates SBOMs for software sold to US federal agencies. Tools like Syft (Anchore) generate SBOMs from container images. Trivy can also generate SBOMs in CycloneDX or SPDX format.

---

**Q: How do you balance security gate strictness with developer velocity?**

- **What is being tested:** Pragmatic DevSecOps thinking.
- **Strong answer:** The key is making security gates fast, actionable, and with a clear path to resolution. If a gate takes 20 minutes and produces 50 findings with no clear owner, developers learn to ignore it. Good practices: (1) Run lightweight checks (SAST, unit tests) on feature branches for fast feedback — not just at merge, (2) Set thresholds that are achievable — CVSS ≥ 7.0 rather than ≥ 4.0 to avoid alert fatigue, (3) Use `ignore-unfixed` in Trivy to not block on unfixable issues, (4) Keep the full image build pipeline for merged code only — don't run Trivy and ECR push on every feature branch commit, (5) Provide clear error messages with remediation guidance, not just "build failed."

---

## 12. Scenario-Based and Design Questions

---

**Q: Design a CI/CD pipeline for a monorepo with 10 microservices. What are your key decisions?**

- **What is being tested:** System design thinking for CI/CD.
- **Strong answer:** Key decisions: (1) **Path filters** — each service's pipeline triggers only when its directory changes, (2) **Reusable workflows** — one `_java-build.yml` called by all Java services, not 10 copies of the same pipeline, (3) **Separate lightweight PR checks** from full build pipelines — fast feedback on feature branches, full security scan + Docker on merged code, (4) **GitOps promotion** — CI never talks to Kubernetes directly, updates a separate GitOps repo, ArgoCD reconciles, (5) **Build Once Deploy Many** — one ECR image per commit, promoted by changing values files, (6) **Image tag strategy** — `sha-<7chars>`, never `:latest`, (7) **Environment gates** — auto for DEV, PR-based for QA, manual dispatch for PROD.

---

**Q: A developer accidentally committed AWS credentials to a feature branch. What do you do?**

- **What is being tested:** Incident response for credential exposure.
- **Strong answer:** Treat it as an active breach — assume the credentials were already scraped by automated GitHub secret scanners (they are real). Immediate steps: (1) Rotate the AWS credentials immediately — do not wait, (2) Check AWS CloudTrail for any API calls made with those credentials in the past hours, (3) Remove the commit from Git history using `git filter-branch` or BFG Repo Cleaner and force-push — even on a feature branch the credentials should be purged from history, (4) Notify the security team, (5) Post-incident: set up Gitleaks or GitHub's secret scanning (which does this automatically) as a pre-commit hook so this cannot happen again.

---

**Q: How would you implement a full audit trail for every production deployment?**

- **What is being tested:** Compliance and auditability design.
- **Strong answer:** In a GitOps model, the audit trail is built in: every deployment is a PR in zen-gitops with an author, timestamp, approvers, and the exact diff showing what image tag changed to what. The PR link is embedded in the Cosign signature in the Rekor transparency log. GitHub Actions run history shows who triggered `promote-prod.yml` and when. ArgoCD sync history shows every sync with the git commit SHA. Combined: you can trace any production deployment to: who approved the code (PR in zen-pharma-backend), who approved the promotion (PR in zen-gitops), who triggered the PROD workflow (GitHub Actions log), what image ran (ECR digest), and what code was in that image (git SHA). This satisfies SOC 2 and most compliance audit requirements.

---

**Q: Your team wants to adopt GitOps but the current setup uses Ansible playbooks and bash scripts that `kubectl apply` directly. How do you migrate?**

- **What is being tested:** Migration strategy and pragmatism.
- **Strong answer:** Migrate incrementally, not all at once. (1) Start by creating the GitOps repo with current cluster state exported using `helm get values` and `kubectl get -o yaml` — this is your baseline, (2) Install ArgoCD and point it at the GitOps repo without enabling auto-sync — ArgoCD will show diffs but not apply them, giving you confidence in the setup, (3) Migrate one non-critical service first with ArgoCD auto-sync enabled — run both the old pipeline and ArgoCD in parallel for a sprint, (4) Once confident, remove the `kubectl apply` from the pipeline for that service and rely on ArgoCD only, (5) Repeat service by service. Never do a big-bang migration — the risk is too high and you lose the ability to roll back the migration itself.

---

**Q: How do you handle database migrations in a GitOps / Kubernetes deployment?**

- **What is being tested:** Real-world deployment complexity awareness.
- **Strong answer:** Database migrations are the hardest part of zero-downtime deployments. Options: (1) **Flyway / Liquibase as a Kubernetes Job** — an init container or a Job runs migrations before the new app pods start; ArgoCD syncs the Job first as a `PreSync` hook, then syncs the Deployment, (2) **Backward-compatible migrations** — always write migrations that the old version of the app can tolerate; add the column in one release, start using it in the next, drop the old column in a third. This allows rolling updates without downtime because old and new pods can coexist, (3) **Never run migrations as part of application startup** — if two pods start simultaneously, both try to run the migration and you get race conditions or lock timeouts.
- **Project context:** Our Java services use Flyway (`needs-database: true` in CI runs a Postgres container to validate migrations pass before the image is built).

---

**Q: What would you change about this pipeline if the company needed to achieve SOC 2 Type II compliance?**

- **What is being tested:** Compliance awareness applied to real architecture.
- **Strong answer:** The pipeline is already well-positioned. Additions for SOC 2: (1) **Formalise the change management evidence** — the zen-gitops PR with approvals is change management evidence; export this to a ticketing system (Jira) per deployment, (2) **SBOM generation** — add Syft or Trivy SBOM output on every build, stored as an artifact, (3) **Enforce branch protection on zen-gitops** — require PR reviews, disallow direct pushes to main, require signed commits, (4) **Audit log retention** — GitHub Actions logs and ArgoCD sync history need to be retained for the compliance period (typically 1 year), export to S3 or a SIEM, (5) **Access reviews** — document who has access to `prod` environment approval in GitHub and the IAM role, review quarterly, (6) **Vulnerability SLA tracking** — CVSS ≥ 9.0 must be remediated within 24 hours, ≥ 7.0 within 30 days; export Trivy and OWASP findings to a tracking system.

---

*This document is tailored to the zen-pharma-backend architecture. Every answer can be given with "In our project, we..." which is significantly stronger than a theoretical answer.*

---

# Part 2 — Terraform & Infrastructure


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
