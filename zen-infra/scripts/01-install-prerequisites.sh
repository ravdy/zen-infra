#!/usr/bin/env bash
# =============================================================================
# Stage 2 - Install Kubernetes Pre-requisites
#
# Installs on the EKS cluster (must already exist from Stage 1 Terraform):
#   1. NGINX Ingress Controller   - exposes services via AWS NLB
#   2. ArgoCD                     - GitOps CD controller
#   3. External Secrets Operator  - syncs AWS Secrets Manager -> K8s Secrets
#
# Run from the root of the dpp-assignment3 directory.
# The script prompts for all required values - nothing is hardcoded.
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

log()  { echo -e "${GREEN}[$(date +%H:%M:%S)] OK  $*${NC}"; }
warn() { echo -e "${YELLOW}[$(date +%H:%M:%S)] !!  $*${NC}"; }
die()  { echo -e "${RED}[$(date +%H:%M:%S)] ERR $*${NC}" >&2; exit 1; }
info() { echo -e "${CYAN}[$(date +%H:%M:%S)]    $*${NC}"; }

# -----------------------------------------------------------------------------
# prompt <var_name> <label> <example> [default]
#
# Prompts the user for a value. Shows an example so the candidate knows
# the expected format. If a default is provided it is shown in brackets;
# pressing Enter accepts it. If the variable is already exported in the
# shell the prompt is skipped entirely.
# -----------------------------------------------------------------------------
prompt() {
  local var_name="$1"
  local label="$2"
  local example="$3"
  local default="${4:-}"
  local current="${!var_name:-}"

  if [[ -n "$current" ]]; then
    info "Using $var_name=$current  (pre-set in environment, skipping prompt)"
    return
  fi

  echo ""
  echo -e "${CYAN}  $label${NC}"
  echo    "    Example : $example"

  if [[ -n "$default" ]]; then
    echo -ne "    Default : $default\n    Your value [press Enter to use default]: "
  else
    echo -ne "    Your value: "
  fi

  read -r input
  local value="${input:-$default}"
  [[ -z "$value" ]] && die "'$label' is required and cannot be empty."
  printf -v "$var_name" '%s' "$value"
  log "  $var_name = $value"
}

# =============================================================================
# Verify required tools are installed
# =============================================================================
echo ""
echo "Checking required tools..."
command -v kubectl >/dev/null 2>&1 || die "kubectl not found. Install: https://kubernetes.io/docs/tasks/tools/"
command -v helm    >/dev/null 2>&1 || die "helm not found. Install: https://helm.sh/docs/intro/install/"
command -v aws     >/dev/null 2>&1 || die "aws CLI not found. Install: https://aws.amazon.com/cli/"
log "kubectl, helm, and aws CLI found."

# =============================================================================
# Collect inputs
# =============================================================================
echo ""
echo "============================================"
echo "  Zen Pharma -- Pre-requisites Installer"
echo "============================================"
echo ""
echo "  This script installs NGINX Ingress, ArgoCD, and External Secrets"
echo "  Operator on your EKS cluster using Helm."
echo ""
echo "  You will be asked for 2 values:"
echo "    1. EKS cluster name  - from Terraform outputs or AWS console"
echo "    2. AWS region        - where your cluster is running"
echo ""

CLUSTER_NAME=""
AWS_REGION=""

prompt CLUSTER_NAME \
  "EKS cluster name" \
  "pharma-dev-cluster" \
  ""

prompt AWS_REGION \
  "AWS region where the cluster is deployed" \
  "us-east-1" \
  "us-east-1"

echo ""
echo "  ----- Configuration Summary -----"
echo "  Cluster : $CLUSTER_NAME"
echo "  Region  : $AWS_REGION"
echo "  ---------------------------------"
echo ""
echo -ne "  Proceed with installation? [Y/n]: "
read -r confirm
[[ "${confirm:-Y}" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
echo ""

# =============================================================================
# Configure kubectl
# =============================================================================
info "Updating kubeconfig for cluster '$CLUSTER_NAME' in '$AWS_REGION'..."
aws eks update-kubeconfig \
  --region "$AWS_REGION" \
  --name   "$CLUSTER_NAME" \
  2>/dev/null || warn "kubeconfig update failed - continuing with existing context"

log "kubectl context: $(kubectl config current-context)"

# =============================================================================
# Add Helm repositories
# =============================================================================
echo ""
info "Adding Helm repositories..."
helm repo add ingress-nginx    https://kubernetes.github.io/ingress-nginx --force-update 2>/dev/null
helm repo add external-secrets https://charts.external-secrets.io         --force-update 2>/dev/null
helm repo add argo             https://argoproj.github.io/argo-helm       --force-update 2>/dev/null
helm repo update
log "Helm repos updated."

# =============================================================================
# Step 1 - NGINX Ingress Controller
#
# Creates an AWS Network Load Balancer that routes external HTTP/S traffic
# into the cluster. All services are exposed through this single NLB.
# =============================================================================
echo ""
echo "--------------------------------------------"
echo "  Step 1 of 3: NGINX Ingress Controller"
echo "--------------------------------------------"

helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --set controller.service.type=LoadBalancer \
  --set controller.service.annotations."service\.beta\.kubernetes\.io/aws-load-balancer-type"="nlb" \
  --set controller.replicaCount=2 \
  --wait --timeout 5m

log "NGINX Ingress Controller installed."

NLB_HOSTNAME=$(kubectl get svc -n ingress-nginx ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "pending")
log "NLB hostname: $NLB_HOSTNAME"
echo "  NOTE: This hostname is your application entry point. Save it."

# =============================================================================
# Step 2 - ArgoCD
#
# GitOps continuous delivery controller. Watches the zen-gitops repository
# and automatically syncs Helm chart values to the EKS cluster.
# =============================================================================
echo ""
echo "--------------------------------------------"
echo "  Step 2 of 3: ArgoCD"
echo "--------------------------------------------"

helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --create-namespace \
  --wait --timeout 10m

ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" 2>/dev/null | base64 -d || \
  kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 --decode)

log "ArgoCD installed."
echo ""
echo "  ============================================================"
echo "  IMPORTANT: Save the ArgoCD credentials below"
echo "  ============================================================"
echo "  Username : admin"
echo "  Password : $ARGOCD_PASSWORD"
echo ""
echo "  To access the ArgoCD UI:"
echo "    kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo "    Then open: https://localhost:8080"
echo "  ============================================================"
echo ""

if [[ -f "zen-gitops/argocd/install/argocd-ingress.yaml" ]]; then
  kubectl apply -f zen-gitops/argocd/install/argocd-ingress.yaml
  log "ArgoCD ingress applied."
fi

# =============================================================================
# Step 3 - External Secrets Operator
#
# Watches ExternalSecret resources in each namespace and pulls secrets from
# AWS Secrets Manager into Kubernetes Secret objects automatically.
# =============================================================================
echo ""
echo "--------------------------------------------"
echo "  Step 3 of 3: External Secrets Operator"
echo "--------------------------------------------"

helm upgrade --install external-secrets external-secrets/external-secrets \
  --namespace external-secrets \
  --create-namespace \
  --set installCRDs=true \
  --wait --timeout 5m

log "External Secrets Operator installed."

# =============================================================================
# Verification
# =============================================================================
echo ""
echo "--------------------------------------------"
echo "  Verification"
echo "--------------------------------------------"
echo ""
echo "NGINX Ingress pods (namespace: ingress-nginx):"
kubectl get pods -n ingress-nginx
echo ""
echo "ArgoCD pods (namespace: argocd):"
kubectl get pods -n argocd
echo ""
echo "External Secrets pods (namespace: external-secrets):"
kubectl get pods -n external-secrets

echo ""
log "All pre-requisites installed successfully."
echo ""
echo "  Summary:"
echo "    NLB hostname : $NLB_HOSTNAME"
echo "    ArgoCD pass  : $ARGOCD_PASSWORD"
echo ""
echo "Next step: ./scripts/02-bootstrap-argocd.sh"
