#!/usr/bin/env bash
# Gera tráfego contínuo no ToggleMaster (dentro do cluster), para alimentar o
# dashboard, os traces no New Relic e a avaliação do alerta.
#
#   ./scripts/load-test.sh start   # cria o pod loadgen
#   ./scripts/load-test.sh logs    # acompanha
#   ./scripts/load-test.sh stop
#
# Cada iteração: GET /evaluate (evaluation -> flag/targeting -> auth, Redis,
# Pub/Sub -> analytics) + GET /flags e GET /rules (-> auth-service /validate).
set -euo pipefail
NS="${NAMESPACE:-togglemaster}"
FLAG="${FLAG_NAME:-demo-flag}"

case "${1:-start}" in
  start)
    kubectl -n "$NS" delete pod loadgen --ignore-not-found >/dev/null
    cat <<YAML | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: loadgen
  namespace: $NS
  labels:
    app: loadgen
spec:
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    runAsUser: 100
  containers:
    - name: loadgen
      image: curlimages/curl:latest
      env:
        - name: KEY
          valueFrom:
            secretKeyRef:
              name: evaluation-service-secret
              key: SERVICE_API_KEY
        - name: FLAG
          value: "$FLAG"
      command: ["/bin/sh", "-c"]
      args:
        - |
          H="Authorization: Bearer \$KEY"
          echo "Semeando a flag \$FLAG e a regra de 50%..."
          curl -s -o /dev/null -X POST http://flag-service:8002/flags -H "\$H" -H 'Content-Type: application/json' \
            -d "{\"name\":\"\$FLAG\",\"description\":\"Flag da demo da Fase 4\",\"is_enabled\":true}"
          curl -s -o /dev/null -X POST http://targeting-service:8003/rules -H "\$H" -H 'Content-Type: application/json' \
            -d "{\"flag_name\":\"\$FLAG\",\"is_enabled\":true,\"rules\":{\"type\":\"PERCENTAGE\",\"value\":50}}"
          i=0
          while true; do
            i=\$((i+1))
            e=\$(curl -s -o /dev/null -w '%{http_code}' "http://evaluation-service:8004/evaluate?user_id=user-\$RANDOM&flag_name=\$FLAG")
            f=\$(curl -s -o /dev/null -w '%{http_code}' -H "\$H" http://flag-service:8002/flags)
            t=\$(curl -s -o /dev/null -w '%{http_code}' -H "\$H" "http://targeting-service:8003/rules/\$FLAG")
            [ \$((i % 20)) -eq 0 ] && echo "\$(date +%T) #\$i evaluate=\$e flags=\$f rules=\$t"
            sleep 0.2
          done
      resources:
        requests: {cpu: 10m, memory: 16Mi}
        limits: {cpu: 100m, memory: 64Mi}
      securityContext:
        allowPrivilegeEscalation: false
        capabilities: {drop: ["ALL"]}
YAML
    echo "loadgen criado. Acompanhe com: $0 logs"
    ;;
  logs) kubectl -n "$NS" logs -f loadgen ;;
  stop) kubectl -n "$NS" delete pod loadgen --ignore-not-found ;;
  *) echo "uso: $0 start|logs|stop"; exit 1 ;;
esac
