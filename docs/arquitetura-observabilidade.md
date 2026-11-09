# Arquitetura de observabilidade — ToggleMaster (Fase 4)

## 1. O fluxo dos três sinais

| Sinal | Origem | Caminho | Destino |
|---|---|---|---|
| **Traces** | SDK OTel nos 5 serviços | OTLP/HTTP → Collector (`k8sattributes`, `batch`) | **New Relic** (`otlp.nr-data.net`) |
| **Métricas de aplicação** | `http.server.request.duration`, `http.client.request.duration`, `self_healer.actions` | OTLP/HTTP → Collector → `prometheusremotewrite` | **Prometheus** |
| **Métricas de infraestrutura** | kubelet/cAdvisor, node-exporter, kube-state-metrics | scrape do Prometheus | **Prometheus** |
| **Logs** | stdout de **todos** os contêineres do cluster | `filelog` (`/var/log/pods`) → Collector (`k8sattributes`, `transform`) | **Loki** (OTLP nativo) e, só os da aplicação, **New Relic** |

O Collector é o único ponto por onde a telemetria das aplicações passa: os
serviços só conhecem a variável `OTEL_EXPORTER_OTLP_ENDPOINT` (ConfigMap
`togglemaster-otel`). Trocar de APM, ou mandar os traces também para um Tempo/Jaeger,
é uma mudança no `values/otel-collector.yaml`, sem rebuild de nenhum serviço.

### Pipelines do Collector

```yaml
traces:        otlp            → memory_limiter, k8sattributes, resource/cluster, batch → otlphttp/newrelic
metrics:       otlp            → memory_limiter, k8sattributes, resource/cluster, batch → prometheusremotewrite
logs:          otlp, filelog   → memory_limiter, k8sattributes, transform/log-service-name, resource/cluster, batch → otlphttp/loki
logs/newrelic: otlp, filelog   → ... + filter/app-logs-only → otlphttp/newrelic
```

- `memory_limiter` primeiro: sob pressão o Collector recusa dados em vez de ser morto por OOM.
- `k8sattributes` adiciona `k8s.pod.name`, `k8s.namespace.name`, `k8s.deployment.name` e `k8s.node.name`.
- `transform/log-service-name` define `service.name` a partir do Deployment
  nos logs do stdout, que chegam sem esse atributo. É o label
  `service_name` no Loki e é o que liga o log à entidade APM no New Relic
  (*logs in context*).
- `filter/app-logs-only` manda para o New Relic só os logs do namespace
  `togglemaster` (e do self-healer), para não gastar a cota gratuita com logs
  do `kube-system`.

### Por que DaemonSet

Um Collector por nó faz duas coisas: lê os arquivos de log dos contêineres
daquele nó e recebe o OTLP dos pods do mesmo nó, porque o Service tem
`internalTrafficPolicy: Local`. Assim o `k8sattributes`, que no DaemonSet só
observa os pods do próprio nó, sempre encontra o pod de origem, e a telemetria
não atravessa a rede entre nós.

## 2. Instrumentação

| Serviço | Linguagem | Como |
|---|---|---|
| auth-service | Go | `otelhttp.NewHandler` (span SERVER + métricas HTTP), `otelsql` (span por query no Postgres) |
| evaluation-service | Go | `otelhttp.NewHandler` + `otelhttp.NewTransport` no client (propaga `traceparent` para flag/targeting), spans manuais de Redis e do *publish* no Pub/Sub com o contexto injetado nos atributos da mensagem |
| flag-service, targeting-service | Python/Flask | `opentelemetry-instrument` (Flask, requests, psycopg2, logging), zero mudança no código das rotas |
| analytics-service | Python/Flask | `opentelemetry-instrument` + span CONSUMER manual que **extrai** o `traceparent` da mensagem do Pub/Sub, e span CLIENT do Firestore |
| self-healer | Python/Flask | `opentelemetry-instrument` + contador `self_healer.actions` |

O trace de um `GET /evaluate` com cache miss fica assim:

```
evaluation-service  GET /evaluate                          SERVER
├─ redis GET                                               CLIENT  (db.system.name=redis)
├─ GET  → flag-service  GET /flags/demo-flag               SERVER
│         ├─ GET → auth-service GET /validate              SERVER
│         │        └─ SELECT api_keys                      CLIENT  (postgresql)
│         └─ SELECT flags                                  CLIENT  (postgresql)
├─ GET  → targeting-service GET /rules/demo-flag           SERVER
│         └─ (mesmo padrão: auth /validate + SELECT)
├─ redis SET                                               CLIENT
└─ evaluation-events publish                               PRODUCER
          └─ analytics-service evaluation-events-sub process   CONSUMER
                   └─ firestore set ToggleMasterAnalytics       CLIENT
```

Isso dá ao **Service Map** os 5 serviços e as dependências (Postgres, Redis,
Pub/Sub, Firestore).

### Semântica das métricas

Go (`otelhttp`) e Python (com `OTEL_SEMCONV_STABILITY_OPT_IN=http`) emitem o
**mesmo** histograma estável `http.server.request.duration` (em segundos), com
`http.response.status_code`. No Prometheus ele vira
`http_server_request_duration_seconds_{count,bucket,sum}`, com `job` igual a
`service.name` e `instance` igual a `service.instance.id` (o nome do pod). Uma
única expressão PromQL serve para os 5 serviços, tanto no dashboard quanto no alerta.

## 3. Alerta, incidente e self-healing

```
Grafana (regra a cada 30s)
  └─ HTTP5xxErrorRateHigh{job=X}  pending (1m) → firing
       └─ contact point "togglemaster-oncall"
            ├─ PagerDuty  → incidente (resolve sozinho quando o alerta resolve)
            ├─ Discord    → mensagem detalhada (resumo, severidade, início, runbook)
            └─ Webhook    → self-healer
                              ├─ valida token, status=firing, allowlist, cooldown
                              ├─ PATCH restartedAt  (= kubectl rollout restart)
                              ├─ Discord: "🔧 Self-healing acionado"
                              └─ acompanha o rollout → Discord: "✅ concluído em Ns"
```

**Por que o alerta é "inteligente"** (anti alert fatigue):

- **Taxa** de erro, e não contagem: 5 erros em 10 mil requisições não acordam ninguém.
- **Tráfego mínimo** (`> 0,2 req/s`): um único 500 num serviço quase ocioso não vira incidente.
- **`for: 1m`**: um pico de segundos não dispara.
- **Agrupamento por `alertname` + `job`**: vira um incidente por serviço, não um por avaliação.
- **`noDataState: OK`**: falta de tráfego não abre incidente falso.
- **Ação acoplada**: o alerta carrega `runbook_url` e o label `remediation: rollout-restart`.

**Guarda-corpos do self-healer**: só age com `status=firing` e em
deployments da allowlist; tem cooldown de 5 min por deployment (se o restart
não resolveu, o problema não está no estado do pod e o incidente continua aberto
para um humano); `DRY_RUN`; RBAC limitado a `get`/`patch` em Deployments do
namespace `togglemaster`.

## 4. Justificativa das escolhas

### New Relic, e não Datadog

| Critério | New Relic | Datadog |
|---|---|---|
| Conta gratuita | Plano free **permanente**: 100 GB/mês de ingestão e 1 usuário full | Free tier sem APM; APM só no trial (14 dias) ou em programas educacionais com prazo |
| OpenTelemetry | Endpoint **OTLP nativo** (`otlp.nr-data.net`): o Collector exporta direto, sem agente proprietário | Recomenda o Datadog Agent / exporter próprio; OTLP puro exige configuração extra |
| Service Map e Distributed Tracing com dados OTel | Nativos para entidades criadas a partir de OTLP | Disponíveis, mas pensados primeiro para o `dd-trace` |
| Lock-in | Baixo: a instrumentação é 100% OTel; trocar de APM é mudar 1 exporter | Maior se o caminho for o agente/tracer proprietário |

Como o enunciado pede o OTel Collector como peça central, o critério decisivo
foi: **qual APM recebe OTLP sem intermediário e sem prazo de expiração?** O New Relic.

### PagerDuty, e não OpsGenie

- A **Atlassian descontinuou o OpsGenie**: novas vendas encerradas em 2025 e
  fim do suporte previsto para 2027, com migração para o Jira Service
  Management / Compass. Seria construir sobre um produto em fim de vida.
- O PagerDuty tem plano **free** (até 5 usuários) com a **Events API v2**, que
  é a integração nativa do Grafana Alerting (contact point `pagerduty`). O
  incidente abre **e resolve** sozinho, pelo `dedup_key` do grupo de alerta.
- Escalonamento, on-call schedules e app mobile (o "acordar o time") são o
  núcleo do produto.

### Grafana Alerting, e não alertas no APM

A regra, o roteamento e os contact points ficam versionados no Git
(`gitops/observability/config/alerting`) e são sincronizados pelo ArgoCD, como
o resto da plataforma. Não dependem da conta comercial e usam a mesma PromQL do
dashboard: o que o time vê é o que dispara.

### Self-healer in-cluster, e não GitHub Action via webhook

A Fase 3 garantiu que o CI **não tem credencial do Kubernetes**. Disparar
`kubectl` a partir de uma Action quebraria esse princípio, colocaria uma fila
de runner (de segundos a minutos) entre o alerta e a mitigação e exigiria
expor uma credencial do GitHub ao Grafana. Dentro do cluster, a reação é
imediata e o privilégio é mínimo e auditável (Role + RoleBinding no Git).
