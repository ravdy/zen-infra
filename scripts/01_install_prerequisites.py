#!/usr/bin/env python3
# =============================================================================
# Stage 2 - Install Kubernetes Pre-requisites
#
# Installs on the EKS cluster (must already exist from Stage 1 Terraform):
#   1. NGINX Ingress Controller   - exposes services via AWS NLB
#   2. ArgoCD                     - GitOps CD controller
#   3. External Secrets Operator  - syncs AWS Secrets Manager -> K8s Secrets
#
# Run from the root of the dpp-assignment3 directory.
# =============================================================================

import os
import subprocess
import sys
from datetime import datetime

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
RED    = "\033[0;31m"
GREEN  = "\033[0;32m"
YELLOW = "\033[1;33m"
CYAN   = "\033[0;36m"
NC     = "\033[0m"

def _ts():
    return datetime.now().strftime("%H:%M:%S")

def log(msg):   print(f"{GREEN}[{_ts()}] OK  {msg}{NC}")
def warn(msg):  print(f"{YELLOW}[{_ts()}] !!  {msg}{NC}")
def info(msg):  print(f"{CYAN}[{_ts()}]    {msg}{NC}")
def die(msg):
    print(f"{RED}[{_ts()}] ERR {msg}{NC}", file=sys.stderr)
    sys.exit(1)

# ---------------------------------------------------------------------------
# run_cmd: run a shell command, streaming output; die on failure unless ok_fail=True
# ---------------------------------------------------------------------------
def run_cmd(args, ok_fail=False, capture=False):
    if capture:
        result = subprocess.run(args, capture_output=True, text=True)
        return result.stdout.strip(), result.returncode
    result = subprocess.run(args)
    if result.returncode != 0 and not ok_fail:
        die(f"Command failed: {' '.join(args)}")
    return None, result.returncode

# ---------------------------------------------------------------------------
# prompt: ask the user for a value, skip if already in environment
# ---------------------------------------------------------------------------
def prompt(var_name, label, example, default=""):
    current = os.environ.get(var_name, "")
    if current:
        info(f"Using {var_name}={current}  (pre-set in environment, skipping prompt)")
        return current

    print()
    print(f"{CYAN}  {label}{NC}")
    print(f"    Example : {example}")

    if default:
        print(f"    Default : {default}")
        raw = input("    Your value [press Enter to use default]: ").strip()
    else:
        raw = input("    Your value: ").strip()

    value = raw if raw else default
    if not value:
        die(f"'{label}' is required and cannot be empty.")

    log(f"  {var_name} = {value}")
    return value

# ---------------------------------------------------------------------------
# Verify required tools are installed
# ---------------------------------------------------------------------------
print()
print("Checking required tools...")
for tool in ["kubectl", "helm", "aws"]:
    rc = subprocess.run(["which", tool], capture_output=True).returncode
    if rc != 0:
        die(f"{tool} not found. Install it before running this script.")
log("kubectl, helm, and aws CLI found.")

# ---------------------------------------------------------------------------
# Collect inputs
# ---------------------------------------------------------------------------
print()
print("============================================")
print("  Zen Pharma -- Pre-requisites Installer")
print("============================================")
print()
print("  This script installs NGINX Ingress, ArgoCD, and External Secrets")
print("  Operator on your EKS cluster using Helm.")
print()
print("  You will be asked for 2 values:")
print("    1. EKS cluster name  - from Terraform outputs or AWS console")
print("    2. AWS region        - where your cluster is running")
print()

CLUSTER_NAME = prompt("CLUSTER_NAME", "EKS cluster name", "pharma-dev-cluster")
AWS_REGION   = prompt("AWS_REGION",   "AWS region where the cluster is deployed",
                      "us-east-1", "us-east-1")

print()
print("  ----- Configuration Summary -----")
print(f"  Cluster : {CLUSTER_NAME}")
print(f"  Region  : {AWS_REGION}")
print("  ---------------------------------")
print()
confirm = input("  Proceed with installation? [Y/n]: ").strip() or "Y"
if confirm.upper() != "Y":
    print("Aborted.")
    sys.exit(0)
print()

# ---------------------------------------------------------------------------
# Configure kubectl
# ---------------------------------------------------------------------------
info(f"Updating kubeconfig for cluster '{CLUSTER_NAME}' in '{AWS_REGION}'...")
_, rc = run_cmd(
    ["aws", "eks", "update-kubeconfig", "--region", AWS_REGION, "--name", CLUSTER_NAME],
    ok_fail=True,
)
if rc != 0:
    warn("kubeconfig update failed - continuing with existing context")

ctx, _ = run_cmd(["kubectl", "config", "current-context"], capture=True)
log(f"kubectl context: {ctx}")

# ---------------------------------------------------------------------------
# Add Helm repositories
# ---------------------------------------------------------------------------
print()
info("Adding Helm repositories...")
for name, url in [
    ("ingress-nginx",    "https://kubernetes.github.io/ingress-nginx"),
    ("external-secrets", "https://charts.external-secrets.io"),
    ("argo",             "https://argoproj.github.io/argo-helm"),
]:
    run_cmd(["helm", "repo", "add", name, url, "--force-update"], ok_fail=True)
run_cmd(["helm", "repo", "update"])
log("Helm repos updated.")

# ---------------------------------------------------------------------------
# Step 1 - NGINX Ingress Controller
# ---------------------------------------------------------------------------
print()
print("--------------------------------------------")
print("  Step 1 of 3: NGINX Ingress Controller")
print("--------------------------------------------")

run_cmd([
    "helm", "upgrade", "--install", "ingress-nginx", "ingress-nginx/ingress-nginx",
    "--namespace", "ingress-nginx",
    "--create-namespace",
    "--set", "controller.service.type=LoadBalancer",
    "--set", "controller.service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-type=nlb",
    "--set", "controller.replicaCount=2",
    "--wait", "--timeout", "5m",
])

log("NGINX Ingress Controller installed.")

nlb_hostname, _ = run_cmd(
    ["kubectl", "get", "svc", "-n", "ingress-nginx", "ingress-nginx-controller",
     "-o", "jsonpath={.status.loadBalancer.ingress[0].hostname}"],
    capture=True, ok_fail=True,
)
nlb_hostname = nlb_hostname or "pending"
log(f"NLB hostname: {nlb_hostname}")
print("  NOTE: This hostname is your application entry point. Save it.")

# ---------------------------------------------------------------------------
# Step 2 - ArgoCD
# ---------------------------------------------------------------------------
print()
print("--------------------------------------------")
print("  Step 2 of 3: ArgoCD")
print("--------------------------------------------")

run_cmd([
    "helm", "upgrade", "--install", "argocd", "argo/argo-cd",
    "--namespace", "argocd",
    "--create-namespace",
    "--wait", "--timeout", "10m",
])

argocd_password_b64, _ = run_cmd(
    ["kubectl", "-n", "argocd", "get", "secret", "argocd-initial-admin-secret",
     "-o", "jsonpath={.data.password}"],
    capture=True,
)
import base64
argocd_password = base64.b64decode(argocd_password_b64).decode().strip()

log("ArgoCD installed.")
print()
print("  ============================================================")
print("  IMPORTANT: Save the ArgoCD credentials below")
print("  ============================================================")
print("  Username : admin")
print(f"  Password : {argocd_password}")
print()
print("  To access the ArgoCD UI:")
print("    kubectl port-forward svc/argocd-server -n argocd 8080:443")
print("    Then open: https://localhost:8080")
print("  ============================================================")
print()

ingress_file = "zen-gitops/argocd/install/argocd-ingress.yaml"
if os.path.isfile(ingress_file):
    run_cmd(["kubectl", "apply", "-f", ingress_file])
    log("ArgoCD ingress applied.")

# ---------------------------------------------------------------------------
# Step 3 - External Secrets Operator
# ---------------------------------------------------------------------------
print()
print("--------------------------------------------")
print("  Step 3 of 3: External Secrets Operator")
print("--------------------------------------------")

run_cmd([
    "helm", "upgrade", "--install", "external-secrets", "external-secrets/external-secrets",
    "--namespace", "external-secrets",
    "--create-namespace",
    "--set", "installCRDs=true",
    "--wait", "--timeout", "5m",
])

log("External Secrets Operator installed.")

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------
print()
print("--------------------------------------------")
print("  Verification")
print("--------------------------------------------")
print()
print("NGINX Ingress pods (namespace: ingress-nginx):")
run_cmd(["kubectl", "get", "pods", "-n", "ingress-nginx"])
print()
print("ArgoCD pods (namespace: argocd):")
run_cmd(["kubectl", "get", "pods", "-n", "argocd"])
print()
print("External Secrets pods (namespace: external-secrets):")
run_cmd(["kubectl", "get", "pods", "-n", "external-secrets"])

print()
log("All pre-requisites installed successfully.")
print()
print("  Summary:")
print(f"    NLB hostname : {nlb_hostname}")
print(f"    ArgoCD pass  : {argocd_password}")
print()
print("Next step: ./scripts/02_bootstrap_argocd.py")
