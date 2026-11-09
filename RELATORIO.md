# Relatório de Entrega — Tech Challenge Fase 3

## Participantes

- Guilherme Maurício Martins — RM `<PREENCHER>`

## Links

- **Repositório:** https://github.com/mgm777/3-CICLO-POS-FIAP
- **Vídeo de demonstração:** `<PREENCHER>`
- **Documentação técnica (runbook passo a passo):** [docs/runbook-infra.md](./docs/runbook-infra.md)
- **README do projeto:** [README.md](./README.md)

## Provedor de nuvem

O enunciado descreve a infraestrutura em AWS. A Fase 2 deste grupo foi entregue
no **Google Cloud**, e a Fase 3 é a continuação direta daquele ambiente — por
isso toda a automação foi feita em GCP, com o equivalente direto de cada serviço
pedido (tabela de correspondência no README). A restrição de IAM do AWS Academy
não se aplica: o projeto `fiap-3-508723` é conta pessoal com billing próprio,
o que corresponde à **Opção B** do enunciado; as service accounts e os papéis de
IAM são todos criados via Terraform.

## O que foi entregue

| Requisito | Estado |
|---|---|
| Terraform modularizado (10 módulos) | ✅ 83 recursos aplicados |
| Backend remoto (bucket versionado) | ✅ `gs://fiap-3-508723-tfstate` |
| Rede, cluster, 3 bancos, cache, NoSQL, fila, 5 registries | ✅ |
| Pipeline por microsserviço com build, lint, SAST, SCA, container scan | ✅ 5 workflows verdes |
| Regra de bloqueio em CRÍTICA | ✅ bloqueou 6 CVEs reais (abaixo) |
| Push no registry com tag do commit | ✅ `v1.0.0-<sha7>` |
| Atualização automática da tag no GitOps | ✅ commits `chore(gitops): …` |
| ArgoCD sincronizando os 5 microsserviços | ✅ 6 Applications `Synced`/`Healthy` |

## Resumo dos desafios encontrados e decisões tomadas

### 1. O state remoto e o problema do ovo e da galinha

O bucket que guarda o `terraform.tfstate` não pode ser criado pelo mesmo
Terraform que o usa como backend — no primeiro `init` ele ainda não existe. A
saída foi um projeto Terraform separado (`terraform/bootstrap`), com state local,
cuja única função é criar o bucket versionado. A partir daí o state sai da
máquina do desenvolvedor, que era exatamente a origem dos "conflitos de versão"
descritos no enunciado.

### 2. Três camadas para eliminar credencial em texto

- As senhas do Postgres são geradas por `random_password` e gravadas no
  **Secret Manager** pelo próprio Terraform. Ninguém digita nem vê a senha.
- Os pods usam **Workload Identity**: cada Deployment roda com uma KSA anotada
  para uma Google Service Account de permissão mínima. Nenhuma chave JSON dentro
  de container.
- O GitHub Actions autentica por **Workload Identity Federation (OIDC)**, com
  uma `attribute_condition` que restringe a federação a este repositório. **Não
  existe `GCP_SA_KEY`** nos secrets — não há segredo de longa duração para vazar.

### 3. O pipeline barrou seis vulnerabilidades críticas reais

Não foi preciso inserir uma vulnerabilidade proposital para demonstrar a regra de
bloqueio: o código herdado da Fase 2 já tinha as suas. O job `docker-build-push`
declara `needs: [build-test, lint, security-scan]`, então em todos os casos a
imagem **nem chegou a ser construída**.

| Serviço | Estágio | CVE | Correção aplicada |
|---|---|---|---|
| `evaluation-service` | SCA (`trivy fs`) | CVE-2026-33186 | `google.golang.org/grpc` v1.63.2 → v1.79.3 |
| `auth-service` | Container scan | CVE-2025-68121 | toolchain Go 1.21 → 1.25 (`crypto/tls` na stdlib) |
| `flag`, `targeting`, `analytics` | Container scan | CVE-2026-8376, CVE-2026-13221, CVE-2026-42496 | `apt-get upgrade` na imagem final (`perl-base` do Debian 13) |

Decisão associada: uma primeira versão bloqueava também em `HIGH`, o que quebrava
a esteira em CVEs transitivos de imagem base sem correção publicada e tornaria a
entrega impossível de demonstrar. O corte ficou em `CRITICAL` — que é o que o
enunciado pede — e `HIGH` é escaneado e impresso no log sem travar o fluxo.

### 4. Migração do Pub/Sub v1 para v2

Ao atualizar as dependências para corrigir a CVE do gRPC, o `staticcheck`
passou a acusar `SA1019`: o pacote `cloud.google.com/go/pubsub` v1 está
deprecado em favor do `pubsub/v2`. A saída rápida seria excluir o aviso no
linter — e foi o que se fez em um primeiro momento, criando dívida técnica
disfarçada de configuração.

A decisão final foi migrar de fato. A API v2 troca o modelo de *topic* por um
de *publisher* com ciclo de vida explícito:

```go
// v1 — o topic é obtido do client e publicado direto
topic = client.Topic(pubsubTopicID)
topic.Publish(ctx, &pubsub.Message{Data: body})

// v2 — publisher com Stop() no encerramento, que garante o flush do buffer
publisher = client.Publisher(pubsubTopicID)
defer publisher.Stop()
publisher.Publish(ctx, &pubsub.Message{Data: body})
```

Com a migração, a exclusão de `SA1019` saiu do `.golangci.yml` — o linter voltou
a rodar com o conjunto padrão completo, sem exceção nenhuma nos serviços Go.
Efeito colateral bem-vindo: o `pubsub/v2` arrasta `google.golang.org/grpc`
para v1.82.1, acima da v1.79.3 que corrigia a CVE-2026-33186.

A lição registrada: **excluir um aviso de linter é decisão de produto, não de
configuração.** Quando a exclusão existe só para silenciar uma migração
pendente, ela esconde exatamente o tipo de dívida que o enunciado desta fase
pede para eliminar.

### 5. Ordem de criação entre Terraform e ArgoCD

As `kubernetes_service_account` com anotação de Workload Identity precisam existir
antes do primeiro sync do ArgoCD, senão os pods sobem sem identidade e falham ao
falar com Cloud SQL e Pub/Sub. Por isso o namespace e as KSAs são criados pelo
Terraform (providers `kubernetes`/`helm` autenticados com token de curta duração
do `google_client_config`), e os Deployments/Services ficam no `gitops/`, sob
responsabilidade do ArgoCD.

### 6. `runAsNonRoot` exige UID numérico

Os Deployments subiam com `CreateContainerConfigError`. O kubelet só consegue
provar que o usuário não é root se o UID for numérico — `USER appuser` no
Dockerfile não basta. Corrigido com `runAsUser: 1000` no `securityContext`.

### 7. Ferramental de CI: três falhas encadeadas

Os cinco workflows falhavam em `startup_failure` sem gerar log de job. Causa:
*Workflow permissions* do repositório em read-only, enquanto os workflows
reutilizáveis declaram `contents: write` para o job de GitOps — o GitHub recusa
o workflow antes de iniciar. Depois disso, a `aquasecurity/trivy-action` falhou
na própria instalação do binário; a solução foi baixar o release oficial em
versão fixa, o que também deixa o scan reproduzível. Por fim, `golangci-lint`
v1.61 não lê módulos Go 1.25 e a action v6 não fala com o golangci-lint v2 —
foi preciso subir os dois juntos.

### 8. Private Service Access

Cloud SQL e Memorystore rodam em um projeto da Google, não no nosso. Alcançá-los
por IP privado exige reservar uma faixa e estabelecer um VPC peering antes — e
esse peering leva minutos. Os módulos de dados recebem o id da conexão como
variável e o declaram em `depends_on`, expressando "espere o peering" sem acoplar
um módulo ao outro.

## Estimativa de custos

`<Inserir print do Google Cloud Pricing Calculator ou de Billing → Reports>`

Composição do ambiente em `us-central1`, 24×7:

| Recurso | Configuração | US$/mês |
|---|---|---|
| GKE — node pool | 2× `e2-standard-2` | ~97 |
| GKE — management fee | zonal (primeiro cluster) | 0 |
| Cloud SQL | 3× `db-f1-micro`, 10 GB | ~30 |
| Memorystore Redis | BASIC, 1 GB | ~35 |
| Cloud NAT | 1 gateway | ~32 |
| Artifact Registry | < 10 GB | ~1 |
| Pub/Sub + Firestore | volume de demonstração | free tier |
| **Total aproximado** | | **~195** |

Cluster zonal em vez de regional é a maior economia isolada: um terço do custo de
controle e criação bem mais rápida. Em produção seria regional, com HA no Cloud
SQL e réplica no Memorystore.

Para não consumir crédito após a entrega: `cd terraform && terraform destroy`.
O bucket de state sobrevive (`force_destroy = false`).
