# Roteiro do vídeo — Fase 4 (até 25 min)

Deixe pronto antes de gravar: 4 terminais, Grafana (`:3000`), ArgoCD (`:8080`),
New Relic, PagerDuty (lista de incidentes) e Discord (canal `#incidentes`)
abertos. Rode `./scripts/load-test.sh start` uns **10 minutos antes**, para os
gráficos e o Service Map já terem dados.

| # | Tempo | O que mostrar | Comandos / onde clicar |
|---|---|---|---|
| 1 | 0:00–2:00 | **Contexto**: o incidente do enunciado e a resposta (métricas, logs, traces, alerta, self-healing) | README, diagrama de arquitetura |
| 2 | 2:00–5:00 | **Visão geral**: GKE de pé (IaC) e ArgoCD com os 5 serviços + `obs-*` + `self-healer` Synced/Healthy | `kubectl get nodes`, `kubectl get pods -n togglemaster`, `kubectl get pods -n observability`, UI do ArgoCD |
| 3 | 5:00–9:00 | **Grafana**: dashboard *ToggleMaster — Saúde do Ecossistema* — linha do cluster (CPU, memória, pods), RED dos serviços (req/s, % 5xx, p95) e logs em tempo real; filtrar um serviço e buscar `error` | Dashboards → ToggleMaster |
| 4 | 9:00–10:30 | **Loki**: busca no Explore | `{k8s_namespace_name="togglemaster", service_name="evaluation-service"} \|= "Cache"` e depois copiar um `trace_id` do log |
| 5 | 10:30–12:30 | **Como o OTel Collector roteia** | `gitops/observability/values/otel-collector.yaml` (pipelines), `kubectl -n observability get ds otel-collector` |
| 6 | 12:30–16:00 | **New Relic**: Service Map com os 5 serviços; fazer uma requisição de teste e abrir o trace distribuído (evaluation → flag/targeting → auth → Postgres; Redis; Pub/Sub → analytics → Firestore) | `kubectl -n togglemaster port-forward svc/evaluation-service 8004:8004` e `curl "localhost:8004/evaluate?user_id=video-1&flag_name=demo-flag"`; no New Relic: *APM → evaluation-service → Distributed tracing* e *Service map* |
| 7 | 16:00–23:00 | **Incidente e self-healing (prova real)** | ver abaixo |
| 8 | 23:00–25:00 | **Fechamento**: decisões (DaemonSet, Grafana Alerting, self-healer in-cluster, New Relic, PagerDuty) | `docs/arquitetura-observabilidade.md` |

## Bloco 7 — a prova real

Terminal 1, pods do auth-service:
```bash
kubectl -n togglemaster get pods -l app=auth-service -w
```
Terminal 2, a automação:
```bash
kubectl -n observability logs -f deploy/self-healer
```
Terminal 3, causar o problema:
```bash
./scripts/chaos.sh on 50
```

Narre enquanto acontece:

1. **(~0:30)** No dashboard, *Taxa de erro HTTP 5xx* do auth-service sobe e passa da linha vermelha de 5%.
   *Ponto-chave:* `kubectl get pods` mostra tudo **Running/Ready**, porque o `/health`
   continua 200. É a "falha silenciosa" do enunciado, que as probes não pegam.
2. **(~1:00)** Grafana → *Alerting → Alert rules* → `HTTP5xxErrorRateHigh` em **Pending**.
3. **(~1:30–2:00)** **Firing**.
4. PagerDuty: incidente **Triggered** "[ToggleMaster] HTTP5xxErrorRateHigh — auth-service".
5. Discord: mensagem 🚨 FIRING com resumo, severidade e runbook, seguida de 🔧 "Self-healing acionado".
6. Terminal 2: `remediation_started` → `rollout_restart_executed` → `rollout_completed`.
7. Terminal 1: pods antigos `Terminating`, pods novos `Running`. **O restart foi feito pela automação, ninguém tocou no cluster.**
8. Discord: ✅ "Self-healing concluído … em Ns".
9. Dashboard: a taxa de erro volta a 0. Em 1–2 min o alerta fica **Normal**, o PagerDuty
   marca o incidente como **Resolved** e o Discord recebe ✅ RESOLVED.
10. Mostrar o painel *Self-healing executados (24h)* em 1 e o histórico do alerta.

> Se quiser mostrar o guarda-corpo: rode `./scripts/chaos.sh on 50` de novo logo
> em seguida. O self-healer registra `skipped / cooldown` e o incidente fica
> aberto para um humano, que é o comportamento certo quando o restart não resolve.

## Prints para o relatório (tire durante a gravação)

- [ ] Dashboard do Grafana completo (com o pico de erro e a recuperação)
- [ ] Trace distribuído no New Relic (waterfall expandido) e o Service Map
- [ ] Mensagens no Discord (FIRING, self-healing acionado, concluído, RESOLVED)
- [ ] Incidente no PagerDuty (Triggered e Resolved, com a timeline)
- [ ] Log do self-healer (`kubectl logs`) e os pods reiniciando
