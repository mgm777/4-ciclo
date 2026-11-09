#!/usr/bin/env bash
# Cria os Secrets da stack de observabilidade (namespace observability).
# Nada disso vai para o Git: os valores vêm de variáveis de ambiente.
#
#   NEW_RELIC_LICENSE_KEY=...  (New Relic > API Keys > INGEST - LICENSE)
#   PAGERDUTY_INTEGRATION_KEY=... (PagerDuty > Service > Integrations > Events API v2)
#   DISCORD_WEBHOOK_URL=...    (Discord > canal > Integrações > Webhooks)
#   ./scripts/create-observability-secrets.sh
#
# Opcionais: GRAFANA_ADMIN_PASSWORD (gerada se ausente) e SELF_HEALER_TOKEN
# (gerado se ausente — é o segredo compartilhado Grafana -> self-healer).
set -euo pipefail

NAMESPACE="${NAMESPACE:-observability}"

: "${NEW_RELIC_LICENSE_KEY:?defina NEW_RELIC_LICENSE_KEY (license key de ingestão do New Relic)}"
: "${PAGERDUTY_INTEGRATION_KEY:?defina PAGERDUTY_INTEGRATION_KEY (Events API v2 do serviço no PagerDuty)}"
: "${DISCORD_WEBHOOK_URL:?defina DISCORD_WEBHOOK_URL (webhook do canal de incidentes no Discord)}"

GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-$(openssl rand -base64 18)}"
SELF_HEALER_TOKEN="${SELF_HEALER_TOKEN:-$(openssl rand -hex 32)}"

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

echo "==> newrelic-license (usado pelo OTel Collector)"
kubectl create secret generic newrelic-license \
  --namespace "$NAMESPACE" \
  --from-literal=license-key="$NEW_RELIC_LICENSE_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "==> grafana-admin"
kubectl create secret generic grafana-admin \
  --namespace "$NAMESPACE" \
  --from-literal=admin-user=admin \
  --from-literal=admin-password="$GRAFANA_ADMIN_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "==> alerting-secrets (Grafana contact points + self-healer)"
kubectl create secret generic alerting-secrets \
  --namespace "$NAMESPACE" \
  --from-literal=PAGERDUTY_INTEGRATION_KEY="$PAGERDUTY_INTEGRATION_KEY" \
  --from-literal=DISCORD_WEBHOOK_URL="$DISCORD_WEBHOOK_URL" \
  --from-literal=SELF_HEALER_TOKEN="$SELF_HEALER_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -

# Pods que já subiram sem o Secret precisam reiniciar para lê-lo.
for d in grafana self-healer; do
  kubectl -n "$NAMESPACE" rollout restart "deployment/$d" 2>/dev/null || true
done
kubectl -n "$NAMESPACE" rollout restart daemonset/otel-collector 2>/dev/null || true

echo
echo "Pronto. Grafana: usuário admin / senha: $GRAFANA_ADMIN_PASSWORD"
echo "  kubectl -n $NAMESPACE port-forward svc/grafana 3000:80"
