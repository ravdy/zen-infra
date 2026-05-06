#!/usr/bin/env bash
# =============================================================================
# Stage 2 - Configure External Secrets Operator
#
# Creates a ClusterSecretStore and ExternalSecrets so pods can pull
# db-credentials and jwt-secret from AWS Secrets Manager automatically.
#
# Uses IRSA (IAM Roles for Service Accounts) - no static AWS keys stored
# anywhere. The IAM role is created by Terraform in Stage 1.
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
# prompt_choice <var_name> <label> <choices...>
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
echo "  Zen Pharma -- External Secrets Setup"
echo "============================================"
echo ""
echo "  This script wires up External Secrets Operator to AWS Secrets Manager"
echo "  using IRSA (IAM Roles for Service Accounts)."
echo ""
echo "  No static AWS keys are stored - pods authenticate via the IAM role"
echo "  that Terraform created in Stage 1."
echo ""
echo "  You will be asked for 4 values:"
echo "    1. Target environment  - dev, qa, or prod"
echo "    2. AWS region          - where Secrets Manager is configured"
echo "    3. AWS account ID      - 12-digit number from AWS console"
echo "    4. ESO IAM role name   - created by Terraform (check Terraform outputs)"
echo ""

ENV=""
AWS_REGION=""
AWS_ACCOUNT_ID=""
ESO_ROLE_NAME=""

prompt_choice ENV \
  "Target environment (determines which Secrets Manager paths to sync)" \
  "dev" "qa" "prod"

prompt AWS_REGION \
  "AWS region where your Secrets Manager secrets are stored" \
  "us-east-1" \
  "us-east-1"

prompt AWS_ACCOUNT_ID \
  "AWS account ID (12-digit number - find it in the top-right of the AWS console)" \
  "123456789012" \
  ""

# Derive the default ESO role name from convention set in Terraform module
DEFAULT_ESO_ROLE_NAME="pharma-${ENV}-eso-role"

prompt ESO_ROLE_NAME \
  "ESO IAM role name (created by Terraform - check 'Terraform Apply' output or AWS IAM console)" \
  "pharma-dev-eso-role" \
  "$DEFAULT_ESO_ROLE_NAME"

ESO_ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${ESO_ROLE_NAME}"

echo ""
echo "  ----- Configuration Summary -----"
echo "  Environment  : $ENV"
echo "  AWS Region   : $AWS_REGION"
echo "  Account ID   : $AWS_ACCOUNT_ID"
echo "  ESO Role ARN : $ESO_ROLE_ARN"
echo "  ---------------------------------"
echo ""
echo "  Secrets will be synced from these Secrets Manager paths:"
echo "    /pharma/$ENV/db-credentials  ->  Kubernetes Secret 'db-credentials'"
echo "    /pharma/$ENV/jwt-secret       ->  Kubernetes Secret 'jwt-secret'"
echo ""
echo -ne "  Continue? [Y/n]: "
read -r confirm
[[ "${confirm:-Y}" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
echo ""

# =============================================================================
# Ensure target namespace exists
# =============================================================================
kubectl create namespace "$ENV" --dry-run=client -o yaml | kubectl apply -f -
log "Namespace '$ENV' ready."

# =============================================================================
# Step 1 - Annotate the ESO service account with the IRSA role ARN
#
# This annotation tells EKS (via the Pod Identity webhook) to inject temporary
# AWS credentials into every pod that runs as this service account. ESO uses
# those credentials to call secretsmanager:GetSecretValue.
# =============================================================================
echo ""
echo "--------------------------------------------"
echo "  Step 1 of 4: IRSA annotation on ESO service account"
echo "--------------------------------------------"
echo ""
echo "  What is IRSA?"
echo "  IRSA (IAM Roles for Service Accounts) lets a Kubernetes service account"
echo "  assume an AWS IAM role. Pods running as that service account automatically"
echo "  get short-lived AWS credentials injected via a projected volume token."
echo "  No passwords or access keys are stored anywhere."
echo ""

kubectl annotate serviceaccount external-secrets \
  --namespace external-secrets \
  "eks.amazonaws.com/role-arn=$ESO_ROLE_ARN" \
  --overwrite

log "ESO service account annotated with IAM role."

# Restart ESO so pods pick up the new annotation
kubectl rollout restart deployment/external-secrets -n external-secrets
kubectl rollout status  deployment/external-secrets -n external-secrets --timeout=120s
log "ESO pods restarted."

# =============================================================================
# Step 2 - ClusterSecretStore (IRSA-based, no static credentials)
#
# ClusterSecretStore is a cluster-wide resource that tells ESO which AWS
# account and region to pull secrets from, and which service account to
# use for authentication.
# =============================================================================
info "Waiting for ESO CRDs to be fully established..."
kubectl wait --for=condition=established \
  crd/clustersecretstores.external-secrets.io \
  crd/externalsecrets.external-secrets.io \
  --timeout=60s

# Clear kubectl discovery cache so it picks up the newly registered CRD types
rm -rf "${HOME}/.kube/cache/discovery"

echo ""
echo "--------------------------------------------"
echo "  Step 2 of 4: ClusterSecretStore (IRSA auth)"
echo "--------------------------------------------"

cat <<EOF | kubectl apply -f -
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: aws-secrets-manager
spec:
  provider:
    aws:
      service: SecretsManager
      region: ${AWS_REGION}
      auth:
        jwt:
          serviceAccountRef:
            name: external-secrets
            namespace: external-secrets
EOF

log "ClusterSecretStore 'aws-secrets-manager' created."

# =============================================================================
# Step 3 - ExternalSecrets for db-credentials and jwt-secret
#
# Each ExternalSecret tells ESO exactly which key to pull from Secrets Manager
# and what to name the resulting Kubernetes Secret key.
# =============================================================================
echo ""
echo "--------------------------------------------"
echo "  Step 3 of 4: ExternalSecrets -> namespace '$ENV'"
echo "--------------------------------------------"

cat <<EOF | kubectl apply -f -
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: db-credentials
  namespace: ${ENV}
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: aws-secrets-manager
    kind: ClusterSecretStore
  target:
    name: db-credentials
    creationPolicy: Owner
  data:
    - secretKey: DB_USERNAME
      remoteRef:
        key: /pharma/${ENV}/db-credentials
        property: username
    - secretKey: DB_PASSWORD
      remoteRef:
        key: /pharma/${ENV}/db-credentials
        property: password
    - secretKey: SPRING_DATASOURCE_USERNAME
      remoteRef:
        key: /pharma/${ENV}/db-credentials
        property: username
    - secretKey: SPRING_DATASOURCE_PASSWORD
      remoteRef:
        key: /pharma/${ENV}/db-credentials
        property: password
EOF

cat <<EOF | kubectl apply -f -
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: jwt-secret
  namespace: ${ENV}
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: aws-secrets-manager
    kind: ClusterSecretStore
  target:
    name: jwt-secret
    creationPolicy: Owner
  data:
    - secretKey: JWT_SECRET
      remoteRef:
        key: /pharma/${ENV}/jwt-secret
        property: secret
EOF

log "ExternalSecrets created in namespace '$ENV'."

# =============================================================================
# Step 4 - Wait for secrets to sync
# =============================================================================
echo ""
echo "--------------------------------------------"
echo "  Step 4 of 4: Waiting for secrets to sync..."
echo "--------------------------------------------"

info "Polling for up to 90 seconds..."
TIMEOUT=90; ELAPSED=0; ALL_SYNCED=false

while [[ $ELAPSED -lt $TIMEOUT ]]; do
  DB_STATUS=$(kubectl get externalsecret db-credentials -n "$ENV" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null || echo "NotFound")
  JWT_STATUS=$(kubectl get externalsecret jwt-secret -n "$ENV" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null || echo "NotFound")

  if [[ "$DB_STATUS" == "SecretSynced" && "$JWT_STATUS" == "SecretSynced" ]]; then
    ALL_SYNCED=true; break
  fi

  echo "  db-credentials: $DB_STATUS | jwt-secret: $JWT_STATUS -- waiting..."
  sleep 10; ELAPSED=$((ELAPSED+10))
done

echo ""
kubectl get externalsecret -n "$ENV"
echo ""

if [[ "$ALL_SYNCED" == "true" ]]; then
  log "Both secrets synced successfully into namespace '$ENV'."
else
  warn "Secrets not yet synced. Common causes:"
  warn ""
  warn "  1. Secrets Manager paths do not exist - create them first:"
  warn "       /pharma/$ENV/db-credentials  (JSON: {\"username\":\"...\",\"password\":\"...\"})"
  warn "       /pharma/$ENV/jwt-secret       (JSON: {\"secret\":\"...\"})"
  warn ""
  warn "  2. IAM role '$ESO_ROLE_NAME' is missing secretsmanager:GetSecretValue"
  warn ""
  warn "  3. OIDC provider not configured on the EKS cluster"
  warn ""
  warn "  Debug command:"
  warn "    kubectl describe externalsecret db-credentials -n $ENV"
fi

echo ""
log "External Secrets setup complete."
echo ""
echo "Next step: ./scripts/04-verify-deployment.sh"
