#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-fiap-3-508723}"
NAMESPACE="${NAMESPACE:-togglemaster}"
TF_DIR="$(cd "$(dirname "$0")/../terraform" && pwd)"

: "${MASTER_KEY:?defina MASTER_KEY antes de rodar (ex.: MASTER_KEY=\$(openssl rand -hex 32))}"

secret_value() {
  gcloud secrets versions access latest --secret="$1" --project="$PROJECT_ID"
}

echo "==> Lendo as DATABASE_URLs do Secret Manager"
AUTH_DB_URL=$(secret_value auth-service-database-url)
FLAG_DB_URL=$(secret_value flag-service-database-url)
TARGETING_DB_URL=$(secret_value targeting-service-database-url)

echo "==> Lendo o endpoint do Redis dos outputs do Terraform"
REDIS_URL=$(cd "$TF_DIR" && terraform output -raw redis_url)

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

echo "==> Criando os Secrets de banco"
kubectl create secret generic auth-service-secret \
  --namespace "$NAMESPACE" \
  --from-literal=DATABASE_URL="$AUTH_DB_URL" \
  --from-literal=MASTER_KEY="$MASTER_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic flag-service-secret \
  --namespace "$NAMESPACE" \
  --from-literal=DATABASE_URL="$FLAG_DB_URL" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic targeting-service-secret \
  --namespace "$NAMESPACE" \
  --from-literal=DATABASE_URL="$TARGETING_DB_URL" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "==> Tentando mintar a API key do evaluation-service no auth-service"
SERVICE_API_KEY=""
if kubectl wait --for=condition=available --timeout=10s \
     "deployment/auth-service" -n "$NAMESPACE" >/dev/null 2>&1; then
  kubectl port-forward -n "$NAMESPACE" svc/auth-service 18001:8001 >/tmp/pf-auth.log 2>&1 &
  PF_PID=$!
  trap 'kill $PF_PID 2>/dev/null || true' EXIT
  sleep 3
  SERVICE_API_KEY=$(curl -sf -X POST http://localhost:18001/admin/keys \
    -H "Authorization: Bearer ${MASTER_KEY}" \
    -H "Content-Type: application/json" \
    -d '{"name":"evaluation-service"}' | python3 -c 'import sys,json; print(json.load(sys.stdin).get("key",""))') || true
  kill $PF_PID 2>/dev/null || true
  trap - EXIT
fi

if [ -n "$SERVICE_API_KEY" ]; then
  echo "    API key mintada com sucesso."
else
  SERVICE_API_KEY="pendente-rode-o-script-de-novo"
  echo "    auth-service ainda nao respondeu; rode este script de novo quando ele estiver Ready." >&2
fi

kubectl create secret generic evaluation-service-secret \
  --namespace "$NAMESPACE" \
  --from-literal=REDIS_URL="$REDIS_URL" \
  --from-literal=SERVICE_API_KEY="$SERVICE_API_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -

echo
echo "Secrets aplicados no namespace '$NAMESPACE':"
kubectl get secrets -n "$NAMESPACE"
