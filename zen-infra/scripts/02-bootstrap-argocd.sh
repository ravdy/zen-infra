#!/usr/bin/env bash
# =============================================================================
# Stage 2 - Bootstrap ArgoCD
#
# After ArgoCD is installed (script 01), this script:
#   1. Registers your zen-gitops repo in ArgoCD
#   2. Creates the pharma AppProject
#   3. Deploys all ArgoCD Application manifests for the target environment
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

# -----------------------------------------------------------------------------
# prompt_secret <var_name> <label> <example>
# Same as prompt but hides input (for tokens and passwords)
# -----------------------------------------------------------------------------
prompt_secret() {
  local var_name="$1"
  local label="$2"
  local example="$3"
  local current="${!var_name:-}"

  if [[ -n "$current" ]]; then
    info "Using $var_name=****** (pre-set in environment, skipping prompt)"
    return
  fi

  echo ""
  echo -e "${CYAN}  $label${NC}"
  echo    "    Example : $example"
  echo -ne "    Your value (input is hidden): "
  read -rs input
  echo ""
  [[ -z "$input" ]] && die "'$label' is required and cannot be empty."
  printf -v "$var_name" '%s' "$input"
  log "  $var_name = ****** (set)"
}

# -----------------------------------------------------------------------------
# prompt_choice <var_name> <label> <choices...>
# Presents a numbered menu for the user to pick from
# -----------------------------------------------------------------------------
prompt_choice() {
  local var_name="$1"
  local label="$2"
  shift 2
  local choices=("$@")
  local current="${!var_name:-}"

  if [[ -n "$current" ]]; then
    info "Using $var_name=$current  (pre-set in environment, skipping prompt)"
    return
  fi

  echo ""
  echo -e "${CYAN}  $label${NC}"
  for i in "${!choices[@]}"; do
    printf "    %d) %s\n" "$((i+1))" "${choices[$i]}"
  done
  echo -ne "    Enter number [1]: "
  read -r input
  local idx=$(( ${input:-1} - 1 ))
  [[ $idx -lt 0 || $idx -ge ${#choices[@]} ]] && die "Invalid choice '$input'."
  printf -v "$var_name" '%s' "${choices[$idx]}"
  log "  $var_name = ${choices[$idx]}"
}

command -v kubectl >/dev/null 2>&1 || die "kubectl not found."

# =============================================================================
# Collect inputs
# =============================================================================
echo ""
echo "============================================"
echo "  Zen Pharma -- ArgoCD Bootstrap"
echo "============================================"
echo ""
echo "  This script registers your zen-gitops repo in ArgoCD,"
echo "  creates the pharma AppProject, and deploys Applications."
echo ""
echo "  You will be asked for 4 values:"
echo "    1. Target environment  - which K8s namespace to deploy to"
echo "    2. GitOps repo URL     - HTTPS URL of your zen-gitops fork"
echo "    3. GitHub username     - your GitHub account name"
echo "    4. GitHub token        - PAT with read access to zen-gitops (input hidden)"
echo ""

ENV=""
GITOPS_REPO_URL=""
GITHUB_USERNAME=""
GITOPS_TOKEN=""

prompt_choice ENV \
  "Target environment (choose the namespace to deploy applications to)" \
  "dev" "qa" "prod"

prompt GITOPS_REPO_URL \
  "GitOps repository HTTPS URL" \
  "https://github.com/your-github-username/zen-gitops.git" \
  ""

prompt GITHUB_USERNAME \
  "Your GitHub username (used for ArgoCD repo authentication)" \
  "your-github-username" \
  ""

prompt_secret GITOPS_TOKEN \
  "GitHub Personal Access Token with read access to zen-gitops" \
  "ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"

echo ""
echo "  ----- Configuration Summary -----"
echo "  Environment   : $ENV"
echo "  GitOps repo   : $GITOPS_REPO_URL"
echo "  GitHub user   : $GITHUB_USERNAME"
echo "  GitHub token  : ******"
echo "  ---------------------------------"
echo ""
echo -ne "  Continue? [Y/n]: "
read -r confirm
[[ "${confirm:-Y}" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
echo ""

ARGOCD_NAMESPACE="argocd"

# =============================================================================
# Verify ArgoCD is running
# =============================================================================
kubectl get deployment argocd-server -n "$ARGOCD_NAMESPACE" >/dev/null 2>&1 \
  || die "ArgoCD not found in namespace '$ARGOCD_NAMESPACE'. Run 01-install-prerequisites.sh first."

# =============================================================================
# Step 1 - Register zen-gitops repo in ArgoCD
#
# ArgoCD watches secrets with the label argocd.argoproj.io/secret-type=repository
# and uses them to authenticate to Git when polling for changes.
# =============================================================================
echo ""
echo "--------------------------------------------"
echo "  Step 1 of 3: Register GitOps repository"
echo "--------------------------------------------"

kubectl create secret generic zen-gitops-repo \
  --namespace "$ARGOCD_NAMESPACE" \
  --from-literal=type=git \
  --from-literal=url="$GITOPS_REPO_URL" \
  --from-literal=username="$GITHUB_USERNAME" \
  --from-literal=password="$GITOPS_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl label secret zen-gitops-repo \
  "argocd.argoproj.io/secret-type=repository" \
  --namespace "$ARGOCD_NAMESPACE" \
  --overwrite

log "GitOps repo '$GITOPS_REPO_URL' registered in ArgoCD."

# =============================================================================
# Step 2 - Create the pharma AppProject
#
# AppProject scopes which repos, namespaces, and cluster resources ArgoCD apps
# in this project are allowed to use. Acts as a security boundary.
# =============================================================================
echo ""
echo "--------------------------------------------"
echo "  Step 2 of 3: Create pharma AppProject"
echo "--------------------------------------------"

PROJECT_FILE="zen-gitops/argocd/projects/pharma-project.yaml"
if [[ -f "$PROJECT_FILE" ]]; then
  sed "s|your-github-username|${GITHUB_USERNAME}|g" "$PROJECT_FILE" | kubectl apply -f -
  log "AppProject applied from $PROJECT_FILE"
else
  warn "$PROJECT_FILE not found - creating AppProject inline."
  cat <<EOF | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: pharma
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  description: Zen Pharma Platform
  sourceRepos:
    - "$GITOPS_REPO_URL"
  destinations:
    - namespace: dev
      server: https://kubernetes.default.svc
    - namespace: qa
      server: https://kubernetes.default.svc
    - namespace: prod
      server: https://kubernetes.default.svc
  clusterResourceWhitelist:
    - group: ''
      kind: Namespace
  namespaceResourceWhitelist:
    - group: '*'
      kind: '*'
EOF
  log "AppProject created."
fi

# =============================================================================
# Step 3 - Deploy ArgoCD Application manifests
#
# Dev: individual Application per service (allows granular sync control)
# QA / Prod: single app-of-apps pointing to the whole envs/<env>/ directory
# =============================================================================
echo ""
echo "--------------------------------------------"
echo "  Step 3 of 3: Deploy Applications ($ENV)"
echo "--------------------------------------------"

APPS_DIR="zen-gitops/argocd/apps/$ENV"
[[ -d "$APPS_DIR" ]] || die "Apps directory not found: $APPS_DIR"

if [[ "$ENV" == "dev" ]]; then
  # Dev: deploy in dependency order (backends before gateway, gateway before UI)
  ORDERED_APPS=(
    "auth-service-app.yaml"
    "catalog-service-app.yaml"
    "inventory-service-app.yaml"
    "supplier-service-app.yaml"
    "manufacturing-service-app.yaml"
    "notification-service-app.yaml"
    "api-gateway-app.yaml"
    "pharma-ui-app.yaml"
  )
  for app_file in "${ORDERED_APPS[@]}"; do
    filepath="$APPS_DIR/$app_file"
    if [[ -f "$filepath" ]]; then
      sed "s|your-github-username|${GITHUB_USERNAME}|g" "$filepath" | kubectl apply -f -
      log "Applied: $app_file"
    else
      warn "Skipping (not found): $filepath"
    fi
  done
else
  sed "s|your-github-username|${GITHUB_USERNAME}|g" "$APPS_DIR/"*.yaml | kubectl apply -f -
  log "Applied all manifests from $APPS_DIR/"
fi

# =============================================================================
# Show sync status
# =============================================================================
echo ""
echo "--------------------------------------------"
echo "  ArgoCD Application Status"
echo "--------------------------------------------"
echo ""
kubectl get applications -n "$ARGOCD_NAMESPACE"

echo ""
log "ArgoCD bootstrap complete for environment: $ENV"
echo ""
echo "  ArgoCD is now syncing. To watch progress:"
echo "    kubectl get applications -n argocd -w"
echo ""
echo "  To open ArgoCD UI:"
echo "    kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo "    Open: https://localhost:8080  (login: admin / <password from script 01>)"
echo ""
echo "Next step: ./scripts/03-setup-external-secrets.sh"
