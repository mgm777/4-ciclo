# Runbook — HTTP5xxErrorRateHigh

**Alerta:** taxa de respostas HTTP 5xx de um microsserviço acima de 5% por mais
de 1 minuto, com tráfego mínimo de 0,2 req/s.
**Severidade:** critical · **Label do serviço:** `job` · **Remediação automática:** `rollout-restart`

## 1. O que já aconteceu sozinho

1. O Grafana abriu o incidente no **PagerDuty** e avisou o **Discord**.
2. O **self-healer** executou `kubectl rollout restart deployment/<job> -n togglemaster`
   e postou no Discord "🔧 Self-healing acionado" e depois "✅ concluído" ou "⚠️ sem sucesso".

Se o alerta **resolveu** em seguida, o incidente do PagerDuty fecha sozinho. Faça
o pós-incidente (seção 4).

## 2. O alerta continua disparando depois do restart

O self-healer não tenta de novo por 5 minutos (cooldown). Se o restart não
resolveu, o problema **não é estado do pod**. Investigue:

```bash
# Saúde dos pods e eventos
kubectl -n togglemaster get pods -l app=<job> -o wide
kubectl -n togglemaster describe deploy/<job> | tail -20

# O que o self-healer decidiu
kubectl -n observability logs deploy/self-healer --since=15m | grep '"event"'

# Erros recentes do serviço (Loki, via Grafana Explore)
#   {k8s_namespace_name="togglemaster", service_name="<job>"} |~ "(?i)error|exception"
```

No **New Relic**, abra *APM → `<job>` → Errors inbox* ou *Distributed tracing*,
filtre por `http.response.status_code >= 500` e veja em qual span o erro nasce:
banco (`SELECT ...`), dependência (`GET → auth-service`) ou o próprio handler.

| Sintoma no trace | Causa provável | Ação |
|---|---|---|
| Span de Postgres com erro/timeout | Cloud SQL indisponível ou sem conexão | `gcloud sql instances describe ...`, checar o IP privado e a senha no Secret |
| Span `GET → auth-service` com 5xx | Falha em cascata a partir do auth | Tratar o auth-service primeiro |
| Erro no handler, logo após um deploy | Regressão de código | Rollback via GitOps: `git revert` do commit `chore(gitops): <job> -> vX` |
| Log `[CHAOS] Falha injetada` | Injeção de falha ligada | `./scripts/chaos.sh off` |

## 3. Desligar a automação (se ela estiver atrapalhando)

```bash
kubectl -n observability set env deploy/self-healer DRY_RUN=true   # só registra, não age
```

O ArgoCD (`selfHeal: true`) volta o valor do Git no próximo sync. Para que a
mudança fique, altere `gitops/self-healer/deployment.yaml`.

## 4. Pós-incidente

- Linha do tempo: Grafana (*Alerting → History*), PagerDuty (*Incident → Timeline*) e Discord.
- Contar quantos restarts automáticos aconteceram: painel *Self-healing executados (24h)* no dashboard.
- Se o restart virou rotina para o mesmo serviço, ele está **escondendo** um
  defeito (vazamento de memória, conexão presa). Abra um item de correção.
