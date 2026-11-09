#!/usr/bin/env bash
# Injeção de falha controlada no auth-service (a "prova real" do vídeo).
#
#   ./scripts/chaos.sh on [error_rate]   # padrão 50% de respostas 500
#   ./scripts/chaos.sh status
#   ./scripts/chaos.sh off
#
# A falha é ligada em TODOS os pods do auth-service, só em memória: o /health
# continua 200 (as probes não percebem — falha silenciosa), mas /validate
# responde 500. O `rollout restart` do self-healer cria pods novos, sem a
# falha — é assim que o self-healing "cura" o serviço.
# A MASTER_KEY nunca sai do pod: a chamada é feita de dentro do contêiner.
set -euo pipefail
NS="${NAMESPACE:-togglemaster}"
ACTION="${1:-status}"
RATE="${2:-50}"

case "$ACTION" in
  on)     QUERY="error_rate=$RATE"; METHOD_ARGS="--post-data=" ;;
  off)    QUERY="error_rate=0";     METHOD_ARGS="--post-data=" ;;
  status) QUERY="";                 METHOD_ARGS="" ;;
  *) echo "uso: $0 on [0-100] | off | status"; exit 1 ;;
esac

for pod in $(kubectl -n "$NS" get pods -l app=auth-service -o jsonpath='{.items[*].metadata.name}'); do
  printf '%-45s ' "$pod"
  kubectl -n "$NS" exec "$pod" -c auth-service -- sh -c \
    "wget -qO- $METHOD_ARGS --header \"Authorization: Bearer \$MASTER_KEY\" 'http://localhost:8001/admin/chaos?$QUERY'"
  echo
done
