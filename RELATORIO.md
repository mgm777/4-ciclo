# Relatório de Entrega — Tech Challenge Fase 4

> Modelo do relatório. Preencha os campos marcados com `TODO`, cole os prints
> e exporte para **PDF**.

## 1. Integrantes

| Nome | RM | Usuário (GitHub/Discord) |
|---|---|---|
| TODO | TODO | TODO |

## 2. Links

- **Repositório:** https://github.com/mgm777/4-ciclo
- **Vídeo de demonstração:** TODO

## 3. Evidências visuais

### 3.1 Dashboard do Grafana
*ToggleMaster — Saúde do Ecossistema*: recursos do cluster, taxa de requisições
e erros dos microsserviços e logs em tempo real (Loki).

TODO: print

### 3.2 Trace distribuído no New Relic
Requisição `GET /evaluate` atravessando evaluation → flag/targeting → auth →
Postgres, Redis e Pub/Sub → analytics → Firestore.

TODO: print do trace · TODO: print do Service Map

### 3.3 Notificação de incidente no ChatOps (Discord)
TODO: print (FIRING + self-healing acionado/concluído + RESOLVED)

### 3.4 Incidente no PagerDuty
TODO: print (Triggered → Resolved)

### 3.5 Execução da automação de Self-Healing
TODO: print do `kubectl -n observability logs deploy/self-healer` e dos pods do auth-service reiniciando

## 4. Justificativa técnica

### 4.1 Arquitetura do OpenTelemetry

Os 5 microsserviços são instrumentados com OpenTelemetry. Nos serviços Go, o
SDK é usado direto no código (`otelhttp`, `otelsql` e spans manuais de Redis e
Pub/Sub). Nos Python, a auto-instrumentação `opentelemetry-instrument` cobre
Flask, requests e psycopg2. Todos exportam OTLP/HTTP para um
**OpenTelemetry Collector em DaemonSet**, a peça central, que:

- recebe traces e métricas via OTLP e coleta, pelo `filelog`, os logs de **todos** os contêineres do nó;
- enriquece tudo com metadados do Kubernetes (`k8sattributes`);
- roteia: **métricas → Prometheus** (remote write), **logs → Loki** (OTLP
  nativo), **traces e logs da aplicação → New Relic** (OTLP).

O contexto W3C (`traceparent`) é propagado nas chamadas HTTP e também nos
atributos das mensagens do Pub/Sub. Por isso o trace segue até o
analytics-service, que é assíncrono.

Detalhes: `docs/arquitetura-observabilidade.md`.

### 4.2 New Relic vs Datadog

Escolhemos o **New Relic** porque o plano gratuito é permanente (100 GB/mês) e
porque ele recebe **OTLP nativamente**: o Collector exporta direto, sem agente
proprietário, e Service Map e Distributed Tracing funcionam com os dados OTel.
Com isso a instrumentação fica 100% padrão aberto, e trocar de APM é mudar um
exporter.

### 4.3 PagerDuty vs OpsGenie

Escolhemos o **PagerDuty**. O OpsGenie foi descontinuado pela Atlassian (fim
das vendas em 2025 e do suporte em 2027). Além disso, o PagerDuty tem plano
gratuito com a Events API v2, que é a integração nativa do Grafana Alerting e
abre e resolve o incidente automaticamente.

### 4.4 Alerta e Self-Healing

A regra `HTTP5xxErrorRateHigh` é avaliada no Grafana: 5xx acima de 5% por
serviço, com tráfego mínimo e `for: 1m`, para evitar alert fatigue. Ela está
versionada no Git. Um único contact point aciona o PagerDuty, o Discord e o
**self-healer**. O self-healer é um serviço de Runbook Automation dentro do
cluster: com RBAC mínimo, ele executa `kubectl rollout restart` no serviço
afetado, acompanha o rollout e informa o resultado no Discord. Tem cooldown e
allowlist para não entrar em loop de remediação.
