#!/usr/bin/env bash
# =============================================================================
# Stage 4 - Verify Deployment
#
# Runs health checks to confirm everything is working:
#   1. Kubernetes pods  - all Running and Ready
#   2. ArgoCD apps      - all Synced and Healthy
#   3. External Secrets - all SecretSynced
#   4. Services/Ingress - resources created
#   5. HTTP endpoints   - health checks via NLB
#
# Run from the root of the dpp-assignment3 directory.
# The script prompts for the target environment.
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BLUE='\033[0;34m'; NC='\033[0m'

log()   { echo -e "${GREEN}[$(date +%H:%M:%S)] OK  $*${NC}"; }
warn()  { echo -e "${YELLOW}[$(date +%H:%M:%S)] !!  $*${NC}"; }
die()   { echo -e "${RED}[$(date +%H:%M:%S)] ERR $*${NC}" >&2; exit 1; }
info()  { echo -e "${BLUE}[$(date +%H:%M:%S)]    $*${NC}"; }
fail()  { echo -e "${RED}[$(date +%H:%M:%S)] FAIL $*${NC}" >&2; ERRORS=$((ERRORS+1)); }

ERRORS=0

command -v kubectl >/dev/null 2>&1 || die "kubectl not found."

# =============================================================================
# Collect inputs
# =============================================================================
echo ""
echo "============================================"
echo "  Zen Pharma -- Deployment Verification"
echo "============================================"
echo ""
echo "  This script checks that all services are healthy in a given environment."
echo ""

ENV="${ENV:-}"

if [[ -z "$ENV" ]]; then
  echo -e "${CYAN}  Target environment (which namespace to check)${NC}"
  echo "    1) dev   - development environment"
  echo "    2) qa    - quality assurance environment"
  echo "    3) prod  - production environment"
  echo -ne "    Enter number [1]: "
  read -r choice
  case "${choice:-1}" in
    1) ENV="dev" ;;
    2) ENV="qa" ;;
    3) ENV="prod" ;;
    *) die "Invalid choice." ;;
  esac
fi

[[ "$ENV" =~ ^(dev|qa|prod)$ ]] || die "ENV must be dev, qa, or prod."

TIMEOUT_PODS="${TIMEOUT_PODS:-300}"
ARGOCD_NS="argocd"

echo ""
echo "  Environment : $ENV"
echo ""

# =============================================================================
# Check 1 - Kubernetes Pods
# All pods in the namespace should be Running and Ready before we check anything else.
# =============================================================================
echo "--------------------------------------------"
echo "  Check 1 of 5: Kubernetes Pods (namespace: $ENV)"
echo "--------------------------------------------"

info "Waiting up to 60s for pods to appear in namespace '$ENV'..."
ELAPSED=0
while [[ $ELAPSED -lt 60 ]]; do
  POD_COUNT=$(kubectl get pods -n "$ENV" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  [[ "$POD_COUNT" -gt 0 ]] && break
  echo "  No pods yet in '$ENV' (${ELAPSED}s elapsed) -- ArgoCD may still be syncing..."
  sleep 10; ELAPSED=$((ELAPSED+10))
done

if [[ $ELAPSED -ge 60 ]]; then
  warn "No pods found in '$ENV' after 60s."
  warn "  ArgoCD may not have synced yet. Check: kubectl get applications -n argocd"
else
  info "Waiting up to ${TIMEOUT_PODS}s for all pods to become Ready..."
  kubectl wait pod --all -n "$ENV" \
    --for=condition=Ready \
    --timeout="${TIMEOUT_PODS}s" \
    2>/dev/null \
    && log "All pods are Running and Ready." \
    || fail "One or more pods are not Ready. See pod list below."
fi

echo ""
kubectl get pods -n "$ENV" -o wide
echo ""

# =============================================================================
# Check 2 - ArgoCD Application health
# All applications should show Synced (Git == cluster) and Healthy (pods OK).
# =============================================================================
echo "--------------------------------------------"
echo "  Check 2 of 5: ArgoCD Application Status"
echo "--------------------------------------------"
echo ""

kubectl get applications -n "$ARGOCD_NS" -o wide 2>/dev/null \
  || warn "No ArgoCD applications found."
echo ""

while IFS= read -r line; do
  APP_NAME=$(echo "$line" | awk '{print $1}')
  SYNC_STATUS=$(echo "$line" | awk '{print $3}')
  HEALTH=$(echo "$line" | awk '{print $4}')
  if [[ "$SYNC_STATUS" != "Synced" || "$HEALTH" != "Healthy" ]]; then
    fail "App '$APP_NAME': sync=$SYNC_STATUS, health=$HEALTH"
  fi
done < <(kubectl get applications -n "$ARGOCD_NS" --no-headers 2>/dev/null || true)

[[ $ERRORS -eq 0 ]] && log "All ArgoCD applications are Synced and Healthy."

# =============================================================================
# Check 3 - External Secrets
# ExternalSecrets should show Ready=True and reason=SecretSynced.
# If not, pods will fail with CreateContainerConfigError (missing secret).
# =============================================================================
echo "--------------------------------------------"
echo "  Check 3 of 5: External Secrets"
echo "--------------------------------------------"
echo ""

kubectl get externalsecret -n "$ENV" 2>/dev/null \
  || warn "No ExternalSecrets found in namespace '$ENV'."
echo ""

while IFS= read -r line; do
  ES_NAME=$(echo "$line" | awk '{print $1}')
  ES_READY=$(echo "$line" | awk '{print $5}')
  if [[ "$ES_READY" != "True" ]]; then
    fail "ExternalSecret '$ES_NAME' is not Ready (Ready=$ES_READY)"
  fi
done < <(kubectl get externalsecret -n "$ENV" --no-headers 2>/dev/null || true)

[[ $ERRORS -eq 0 ]] && log "All ExternalSecrets are synced."

# =============================================================================
# Check 4 - Services and Ingress
# =============================================================================
echo "--------------------------------------------"
echo "  Check 4 of 5: Services and Ingress"
echo "--------------------------------------------"
echo ""

kubectl get svc -n "$ENV"
echo ""
kubectl get ingress -n "$ENV" 2>/dev/null || info "No ingress resources in '$ENV'."
echo ""

NLB_HOSTNAME=$(kubectl get svc -n ingress-nginx ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")

if [[ -n "$NLB_HOSTNAME" ]]; then
  log "NLB hostname: $NLB_HOSTNAME"
else
  warn "NLB hostname not available yet -- skipping HTTP endpoint checks."
fi

# =============================================================================
# Check 5 - HTTP health endpoints
# Calls /actuator/health on each backend service and / on the frontend.
# Expects HTTP 200, 301, or 302 within 10 seconds.
# =============================================================================
if [[ -n "$NLB_HOSTNAME" ]]; then
  echo "--------------------------------------------"
  echo "  Check 5 of 5: HTTP Endpoint Health"
  echo "--------------------------------------------"
  echo ""

  # Service name -> path that returns 200 when the service is healthy
  declare -A HEALTH_PATHS=(
    ["pharma-ui"]="/"
    ["api-gateway"]="/api/actuator/health"
    ["auth-service"]="/api/auth/actuator/health"
    ["drug-catalog-service"]="/api/catalog/actuator/health"
    ["inventory-service"]="/api/inventory/actuator/health"
    ["supplier-service"]="/api/suppliers/actuator/health"
    ["manufacturing-service"]="/api/manufacturing/actuator/health"
  )

  BASE_URL="http://$NLB_HOSTNAME"
  command -v curl >/dev/null 2>&1 || { warn "curl not found -- skipping HTTP checks."; }

  for service in "${!HEALTH_PATHS[@]}"; do
    url="$BASE_URL${HEALTH_PATHS[$service]}"
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$url" 2>/dev/null || echo "000")
    if [[ "$HTTP_CODE" =~ ^(200|301|302)$ ]]; then
      log "$service: HTTP $HTTP_CODE  <--  $url"
    else
      fail "$service: HTTP $HTTP_CODE  <--  $url  (expected 200/301/302)"
    fi
  done
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "============================================"
if [[ $ERRORS -eq 0 ]]; then
  echo -e "${GREEN}  ALL CHECKS PASSED${NC}"
  echo ""
  [[ -n "${NLB_HOSTNAME:-}" ]] && echo "  Application URL : http://$NLB_HOSTNAME/"
  echo "  ArgoCD UI       : https://localhost:8080"
  echo "                    (kubectl port-forward svc/argocd-server -n argocd 8080:443)"
else
  echo -e "${RED}  $ERRORS CHECK(S) FAILED${NC}"
  echo ""
  echo "  Troubleshooting commands:"
  echo "    kubectl describe pod <pod-name> -n $ENV"
  echo "    kubectl logs -n $ENV deployment/<service-name> --previous"
  echo "    kubectl describe externalsecret db-credentials -n $ENV"
  echo "    kubectl get applications -n argocd"
fi
echo "============================================"
echo ""

exit $ERRORS
