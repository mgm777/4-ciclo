# Tech Challenge Fase 4 — ToggleMaster: Observabilidade Total e Resposta Ativa

Continuação do projeto das Fases 1–3: os 5 microsserviços do ToggleMaster
(`auth`, `flag`, `targeting`, `evaluation`, `analytics`) rodando no **GKE**,
com infraestrutura em **Terraform**, CI/CD com **DevSecOps** (GitHub Actions)
e entrega via **GitOps** (ArgoCD). Esta fase adiciona:

| Requisito | Implementação |
|---|---|
| Métricas de infraestrutura | **Prometheus** (kube-prometheus-stack: kubelet/cAdvisor, node-exporter, kube-state-metrics) |
| Logs centralizados | **Loki** (SingleBinary), alimentado pelo OTel Collector com os logs de **todos** os contêineres |
| Visualização | **Grafana** com o dashboard customizado *ToggleMaster — Saúde do Ecossistema* (provisionado como código) |
| Padronização da telemetria | **OpenTelemetry Collector** (DaemonSet) recebendo OTLP dos serviços e roteando métricas → Prometheus, logs → Loki, traces → New Relic |
| Instrumentação | SDK OTel no código Go (`otelhttp`, `otelsql`, spans de Redis/Pub/Sub) e auto-instrumentação Python (`opentelemetry-instrument`) |
| APM, Distributed Tracing e Service Map | **New Relic** (OTLP nativo), com contexto propagado inclusive através do **Pub/Sub** |
| Alerta inteligente | **Grafana Alerting**: taxa de 5xx > 5% por serviço, com tráfego mínimo e `for: 1m` |
| Gestão de incidentes | **PagerDuty** (Events API v2) — abre e resolve o incidente sozinho |
| ChatOps | **Discord** — notificação detalhada do alerta e do resultado do self-healing |
| Self-Healing | **self-healer** (Runbook Automation in-cluster) — executa `kubectl rollout restart` no serviço afetado |

Tudo é código e é sincronizado pelo ArgoCD: os Helm charts, os values, o
dashboard e as regras/contact points/políticas de alerta.

## Arquitetura

```
                        ┌────────────────────────── GKE ───────────────────────────┐
  usuário ─► evaluation ─┬─► flag ──────┐                                           │
             -service    ├─► targeting ─┴─► auth ─► Cloud SQL                       │
               │  │      └─► Redis                                                 │
               │  └─► Pub/Sub ─► analytics ─► Firestore     (traceparent na msg)   │
               │                                                                   │
               │ OTLP/HTTP (traces + métricas)          stdout de todos os pods    │
               ▼                                                 ▼                 │
        ┌──────────────────── OTel Collector (DaemonSet) ─────────────────────┐    │
        │ receivers: otlp, filelog │ processors: memory_limiter, k8sattributes│    │
        │                          │ transform, filter, batch                 │    │
        └───┬──────────────────────────┬──────────────────────────┬──────────┘    │
            │ remote write             │ OTLP                     │ OTLP           │
            ▼                          ▼                          │                │
       Prometheus ◄── scrape infra   Loki                         │                │
            └──────────┬───────────────┘                          │                │
                       ▼                                          │                │
                    Grafana ── alerta 5xx > 5% ──┬─► PagerDuty    │                │
                                                 ├─► Discord      │                │
                                                 └─► self-healer ─┼─► rollout      │
                                                                  │    restart     │
└─────────────────────────────────────────────────────────────────┼────────────────┘
                                                                  ▼
                                                     New Relic (APM, traces,
                                                     Service Map, logs in context)
```

Detalhes e justificativas: [docs/arquitetura-observabilidade.md](docs/arquitetura-observabilidade.md).
Runbook do incidente: [docs/runbook-incidente.md](docs/runbook-incidente.md).
Roteiro do vídeo: [docs/roteiro-video-fase4.md](docs/roteiro-video-fase4.md).

## Estrutura do repositório

```
services/                     5 microsserviços (Go e Python) + self-healer
  auth-service/chaos.go       injeção de falha para a demonstração
  */telemetry.go              bootstrap OpenTelemetry (serviços Go)
terraform/                    infraestrutura (inalterada, + repositório do self-healer)
gitops/
  argocd-apps/                Applications do ArgoCD (serviços + obs-*)
  observability/values/       values dos charts: kube-prometheus-stack, loki, otel-collector
  observability/config/       dashboard JSON + alerting (rules, contact points, policies)
  self-healer/                Deployment, RBAC mínimo e Service do self-healer
  <serviço>/                  manifestos dos microsserviços (agora com OTEL_*)
  platform/                   ConfigMaps compartilhados (incl. togglemaster-otel)
scripts/
  create-secrets.sh           Secrets das aplicações (Fase 3)
  create-observability-secrets.sh  Secrets de New Relic / PagerDuty / Discord / Grafana
  load-test.sh                gerador de tráfego dentro do cluster
  chaos.sh                    liga/desliga a falha no auth-service
  gen-dashboard.py            gera o JSON do dashboard
docs/                         arquitetura, runbooks, roteiro do vídeo; docs/fase3/ = histórico
```

## Passo a passo

### 0. Base das Fases 1–3

Infraestrutura e pipelines seguem o procedimento da Fase 3
([docs/fase3/README-fase3.md](docs/fase3/README-fase3.md) e
[docs/runbook-infra.md](docs/runbook-infra.md)). Mudanças desta fase:

- O repositório agora é `mgm777/4-ciclo`. Em `terraform/terraform.tfvars`,
  ajuste `github_repository = "mgm777/4-ciclo"` e rode `terraform apply`
  — isso atualiza a federação OIDC do CI **e** cria o repositório
  `self-healer` no Artifact Registry.
- Configure no GitHub os mesmos secrets da Fase 3 (`GCP_WIF_PROVIDER`,
  `GCP_CI_SERVICE_ACCOUNT`, `GCP_PROJECT_ID`, `GCP_REGION`) e as
  *Workflow permissions* em **Read and write**.

### 1. Contas externas (todas gratuitas)

| Serviço | O que pegar |
|---|---|
| **New Relic** | *API Keys* → chave do tipo **INGEST - LICENSE** |
| **PagerDuty** | Crie um *Service* "ToggleMaster" → *Integrations* → **Events API V2** → *Integration Key* |
| **Discord** | Canal `#incidentes` → *Editar canal* → *Integrações* → *Webhooks* → **Copiar URL** |

### 2. Secrets da observabilidade (nunca vão para o Git)

```bash
export NEW_RELIC_LICENSE_KEY=...
export PAGERDUTY_INTEGRATION_KEY=...
export DISCORD_WEBHOOK_URL=https://discord.com/api/webhooks/...
./scripts/create-observability-secrets.sh
```

### 3. Registrar as Applications no ArgoCD

```bash
kubectl apply -f gitops/argocd-apps/
kubectl get applications -n argocd
```

Ordem (sync waves): `obs-kube-prometheus-stack` e `obs-loki` → `obs-otel-collector`
→ `obs-grafana-config`. Os 5 serviços e o `self-healer` são publicados pelo CI
no primeiro push (todos os serviços mudaram, então os 6 pipelines rodam e
reescrevem as tags em `gitops/`).

### 4. Acessar as ferramentas

```bash
kubectl -n observability port-forward svc/grafana 3000:80          # Grafana (admin / senha do passo 2)
kubectl -n argocd        port-forward svc/argocd-server 8080:443   # ArgoCD
```

- Dashboard: *Dashboards → ToggleMaster → ToggleMaster — Saúde do Ecossistema*
- Logs: *Explore → Loki* → `{k8s_namespace_name="togglemaster"}`
- APM: New Relic → *APM & Services* → `evaluation-service` → *Distributed tracing* / *Service map*

### 5. Demonstração do incidente (a "prova real")

```bash
./scripts/load-test.sh start          # tráfego contínuo
./scripts/chaos.sh on 50              # auth-service passa a responder 500 em 50% das requisições
kubectl -n togglemaster get pods -l app=auth-service -w    # em outro terminal
kubectl -n observability logs -f deploy/self-healer       # em outro terminal
```

Em ~2 minutos: alerta **Firing** no Grafana → incidente no **PagerDuty** →
mensagem no **Discord** → o self-healer executa o `rollout restart` → pods
novos (sem a falha) → taxa de erro volta a 0 → alerta **Resolved** (o
PagerDuty resolve o incidente e o Discord recebe o ✅).

## Decisões e trade-offs da Fase 4

- **OTel Collector como DaemonSet** (e não Deployment): um único componente
  coleta os logs de todos os contêineres do nó (filelog) e recebe o OTLP dos
  pods do mesmo nó (`internalTrafficPolicy: Local`), o que mantém o
  `k8sattributes` exato e evita tráfego entre nós.
- **Métricas das apps por remote write**, não por scrape: o Collector é o único
  caminho da telemetria das aplicações, como pede o enunciado.
- **Logs pelo stdout + filelog** em vez do exportador de logs OTLP no SDK:
  pega também os logs de contêineres não instrumentados (ArgoCD, kube-system…)
  e não duplica. O `trace_id` vai na linha de log para a correlação.
- **Gunicorn com 1 processo e threads**: com vários workers forkados, cada
  processo exportaria séries de métrica idênticas e os contadores colidiriam
  no Prometheus. Por isso o pool do Postgres passou a ser o `ThreadedConnectionPool`.
- **Alerta no Grafana (não no APM)**: a regra fica versionada no Git junto com
  o restante e não depende da conta comercial; o APM fica com o que ele faz
  melhor (traces e Service Map).
- **Self-healer dentro do cluster** em vez de GitHub Action via webhook: o CI
  continua **sem credencial do Kubernetes** (princípio da Fase 3), a reação
  leva segundos (sem fila de runner) e o RBAC é mínimo (`get`/`patch` em
  Deployments de um namespace). Guarda-corpos: allowlist, cooldown de 5 min e
  `DRY_RUN`.
- **Alertmanager desligado**: o roteamento é todo do Grafana Alerting, para não
  ter dois sistemas de notificação concorrentes.
