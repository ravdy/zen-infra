# EKS Prerequisites Setup — Zen Pharma

Setup guide for installing cluster prerequisites on `pharma-dev-cluster` to support the Zen Pharma platform.

---

## Prerequisites

- `kubectl` configured: `aws eks update-kubeconfig --region us-east-1 --name pharma-dev-cluster`
- `helm` v3+ installed
- Helm repos added:

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo add external-secrets https://charts.external-secrets.io
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
```

---

## Step 1 — NGINX Ingress Controller

Exposes services outside the cluster via an AWS Network Load Balancer.

```bash
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --set controller.service.type=LoadBalancer \
  --set controller.service.annotations."service\.beta\.kubernetes\.io/aws-load-balancer-type"="nlb" \
  --wait --timeout 5m
```

**Verify:**

```bash
kubectl get svc -n ingress-nginx
```

Note the `EXTERNAL-IP` (NLB DNS hostname) — update `ingress.host` in `zen-gitops/envs/dev/values-pharma-ui.yaml` with this value.

---

## Step 2 — ArgoCD

GitOps continuous delivery controller that syncs manifests from `zen-gitops` to the cluster.

```bash
# Create namespace
kubectl apply -f zen-gitops/argocd/install/argocd-namespace.yaml

# Install ArgoCD
kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Wait for server to be ready
kubectl wait --for=condition=available --timeout=300s \
  deployment/argocd-server -n argocd
```

**Get initial admin password:**

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo
```

**Apply ingress** (after NGINX controller is ready):

```bash
kubectl apply -f zen-gitops/argocd/install/argocd-ingress.yaml
```

> ArgoCD UI will be available at `https://argocd.pharma.internal` once DNS is configured.

---

## Step 3 — External Secrets Operator

Syncs secrets from AWS Secrets Manager into Kubernetes `Secret` objects.

```bash
helm upgrade --install external-secrets external-secrets/external-secrets \
  --namespace external-secrets \
  --create-namespace \
  --set installCRDs=true \
  --wait --timeout 5m
```

**Verify:**

```bash
kubectl get pods -n external-secrets
kubectl get crd | grep external-secrets
```

---

## Step 4 — Deploy Frontend via ArgoCD

With all prerequisites running, register the ArgoCD project and deploy the `pharma-ui` application.

```bash
# Create ArgoCD project
kubectl apply -f zen-gitops/argocd/projects/pharma-project.yaml

# Deploy pharma-ui to dev
kubectl apply -f zen-gitops/argocd/apps/dev/pharma-ui-app.yaml
```

**Watch sync status:**

```bash
kubectl get application pharma-ui-dev -n argocd -w
```

**Check deployed pods:**

```bash
kubectl get pods -n dev
kubectl get ingress -n dev
```

---

## Installed Components Summary

| Component | Namespace | Purpose |
|---|---|---|
| ingress-nginx | `ingress-nginx` | Route external HTTP/S traffic into the cluster |
| argocd | `argocd` | GitOps sync from `zen-gitops` repo |
| external-secrets | `external-secrets` | Pull secrets from AWS Secrets Manager |
| pharma-ui | `dev` | React frontend served via Nginx |

---

## Relevant Files

| File | Description |
|---|---|
| `zen-gitops/argocd/install/argocd-namespace.yaml` | ArgoCD namespace definition |
| `zen-gitops/argocd/install/argocd-ingress.yaml` | ArgoCD server ingress |
| `zen-gitops/argocd/projects/pharma-project.yaml` | ArgoCD AppProject for pharma |
| `zen-gitops/argocd/apps/dev/pharma-ui-app.yaml` | ArgoCD Application for pharma-ui (dev) |
| `zen-gitops/envs/dev/values-pharma-ui.yaml` | Helm values for pharma-ui (dev) |
