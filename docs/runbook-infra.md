# Runbook — como esta infraestrutura foi construída

O caminho exato percorrido para provisionar 85 recursos no Google Cloud com
Terraform, ligar um pipeline DevSecOps no GitHub Actions e entregar deploy por
GitOps com ArgoCD — incluindo os erros que apareceram no meio e como cada um foi
resolvido. Serve como referência para reproduzir o ambiente do zero.

| | |
|---|---|
| Projeto | `fiap-3-508723` |
| Região | `us-central1` |
| Recursos no state | 85 |
| Módulos Terraform | 10 |
| Microsserviços | 5 |
| Chaves estáticas | 0 |

---

## Antes de começar

### 1. Toolchain local

`mise` resolve Terraform, kubectl e Helm em uma linha. O gcloud não está nos
repositórios oficiais do Arch, então vem do tarball oficial.

```bash
mise use -g terraform@latest kubectl@latest helm@latest

curl -sSL -o /tmp/gcloud.tar.gz \
  https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-linux-x86_64.tar.gz
tar -xzf /tmp/gcloud.tar.gz -C ~/.local/share
~/.local/share/google-cloud-sdk/install.sh -q --path-update false
ln -sf ~/.local/share/google-cloud-sdk/bin/gcloud ~/.local/bin/gcloud
```

> **Armadilha.** O instalador com `--path-update false` não mexe no shell. Sem o
> symlink em um diretório já presente no `PATH`, o binário existe mas `gcloud`
> responde "command not found" — e se perde tempo achando que a instalação falhou.

Para o `kubectl` falar com o GKE também é preciso o plugin de autenticação:

```bash
gcloud components install gke-gcloud-auth-plugin
```

### 2. Autenticação: são duas credenciais diferentes

`gcloud auth login` autentica o **CLI**. O Terraform não usa essa credencial — ele
usa **Application Default Credentials**, que é outro arquivo. São dois logins
distintos, e é o segundo que importa para o IaC.

```bash
gcloud auth login                        # credencial do CLI
gcloud auth application-default login    # credencial do Terraform (ADC)
gcloud config set project fiap-3-508723
```

> **Alternativa quando o ADC falha.**
> `export GOOGLE_OAUTH_ACCESS_TOKEN=$(gcloud auth print-access-token)` faz o
> provider google funcionar com o token do CLI. Destrava, mas expira em ~1h — se
> o apply for longo, ele morre no meio.

### 3. Habilitar as APIs antes do Terraform

O Terraform tem um módulo que habilita as APIs, mas existe um ovo-e-galinha: para
habilitar APIs ele precisa da `serviceusage` e da `cloudresourcemanager` já
ligadas. Habilitar à mão primeiro evita um `apply` que falha no primeiro recurso.

```bash
gcloud services enable \
  compute container artifactregistry sqladmin redis pubsub \
  firestore secretmanager iam iamcredentials sts \
  cloudresourcemanager servicenetworking storage \
  --project fiap-3-508723   # sufixo .googleapis.com em cada uma
```

---

## O state remoto

### 4. Bootstrap: o bucket que não pode se auto-hospedar

O bucket que guarda o `terraform.tfstate` não pode ser criado pelo mesmo Terraform
que o usa como backend — no primeiro `init` ele ainda não existe. A saída é um
projeto Terraform **separado**, com state local, cuja única função é criar o bucket.

```bash
cd terraform/bootstrap
terraform init
terraform plan  -var project_id=fiap-3-508723 -out=tfplan.bin
terraform apply tfplan.bin
# google_storage_bucket.tfstate: Creation complete after 3s
# bucket_name = "fiap-3-508723-tfstate"
```

O bucket nasce com **versioning ligado** (dá para voltar a um state anterior se um
apply corromper o arquivo), `public_access_prevention` em `enforced` e uma
lifecycle rule que mantém as 20 versões mais recentes.

### 5. Apontar o backend

O bloco `backend` **não aceita variáveis** — é avaliado antes de qualquer expressão
do Terraform. O nome do bucket entra literal.

```hcl
# terraform/backend.tf
terraform {
  backend "gcs" {
    bucket = "fiap-3-508723-tfstate"
    prefix = "fase3/togglemaster"
  }
}
```

A partir daqui o state sai da máquina do desenvolvedor — que era exatamente a
origem dos "conflitos de versão" descritos no enunciado. O GCS também faz lock de
objeto nativamente, então não é preciso uma tabela extra só para travamento (o
equivalente ao lock em DynamoDB do backend S3).

---

## A infraestrutura, em módulos

### 6. O mapa AWS → GCP

| Enunciado (AWS) | Implementado (GCP) | Módulo |
|---|---|---|
| VPC, Subnets, IGW, Route Tables | VPC custom + Subnet com ranges secundários + Cloud Router/NAT | `networking` |
| EKS + Node Groups | GKE zonal + Node Pool com autoscaling | `gke` |
| 3× RDS PostgreSQL | 3× Cloud SQL Postgres 15, IP privado | `cloudsql` |
| ElastiCache Redis | Memorystore for Redis 7.0, tier BASIC | `memorystore` |
| DynamoDB `ToggleMasterAnalytics` | Firestore Native, coleção homônima | `firestore` |
| Fila SQS | Pub/Sub: tópico + subscription + DLQ | `messaging` |
| 5× repositórios ECR | 5× repositórios Artifact Registry | `artifact-registry` |
| Backend S3 | Backend GCS versionado | `bootstrap` |

### 7. Private Service Access: a dependência que não é óbvia

Cloud SQL e Memorystore são serviços gerenciados que rodam em um projeto da
Google, não no seu. Para alcançá-los por IP privado é preciso reservar uma faixa e
estabelecer um **VPC peering** antes — e esse peering leva alguns minutos. Sem ele,
os recursos de banco falham no apply.

```hcl
resource "google_compute_global_address" "private_service_range" {
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 20
  network       = google_compute_network.vpc.id
}

resource "google_service_networking_connection" "private_vpc_connection" {
  network                 = google_compute_network.vpc.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_service_range.name]
}
```

> **Padrão útil.** Os módulos `cloudsql` e `memorystore` recebem o id dessa conexão
> como variável e a declaram em `depends_on`. É assim que se expressa "espere o
> peering" entre módulos sem acoplar um ao outro.

### 8. Workload Identity: como o pod se autentica sem chave

Esta é a resposta técnica à dor "credenciais em arquivos de texto sem segurança".
São **duas metades que precisam casar**: uma Google Service Account (GSA) com as
permissões, e uma Kubernetes Service Account (KSA) anotada apontando para ela. O
GKE troca o token da KSA por um token da GSA no metadata server.

```hcl
# metade 1 — no GCP: autoriza a KSA a personificar a GSA
resource "google_service_account_iam_member" "workload_identity" {
  service_account_id = google_service_account.app[each.value].name
  role               = "roles/iam.workloadIdentityUser"
  member = "serviceAccount:${var.project_id}.svc.id.goog[togglemaster/${each.value}-ksa]"
}
```

```yaml
# metade 2 — no cluster: a KSA aponta de volta para a GSA
annotations:
  iam.gke.io/gcp-service-account: auth-service-gsa@fiap-3-508723.iam.gserviceaccount.com
```

O cluster precisa de `workload_identity_config` e o node pool de
`workload_metadata_config { mode = "GKE_METADATA" }` — sem os dois, o pod herda
silenciosamente a identidade do node e o mecanismo não funciona.

> **Ordem importa.** As KSAs precisam existir *antes* do ArgoCD sincronizar os
> Deployments. Por isso o namespace e as KSAs são criados pelo Terraform, e só os
> Deployments e Services ficam sob o ArgoCD. Invertendo isso, os pods sobem sem
> identidade e falham ao falar com Cloud SQL e Pub/Sub.

### 9. Senhas que ninguém digita

As senhas do Postgres são geradas por `random_password` e a `DATABASE_URL`
completa vai direto para o **Secret Manager**. Nenhum humano vê a senha, nada vai
para o git, e cada serviço recebe permissão de leitura apenas do *seu* secret.

```hcl
resource "google_secret_manager_secret_version" "database_url" {
  secret      = google_secret_manager_secret.database_url[each.key].id
  secret_data = format(
    "postgres://%s:%s@%s:5432/%s?sslmode=disable",
    each.value.user_name,
    random_password.db[each.key].result,
    google_sql_database_instance.postgres[each.key].private_ip_address,
    each.value.db_name,
  )
}
```

O script que cria os Secrets do Kubernetes lê de lá
(`gcloud secrets versions access latest`) em vez de receber a senha como argumento.

### 10. ArgoCD no mesmo apply

"Se não está no código, não existe" vale também para o ArgoCD. Os providers
`kubernetes` e `helm` são configurados com os outputs do cluster e um token de
curta duração — sem kubeconfig em disco, sem chave.

```hcl
provider "helm" {
  kubernetes {
    host                   = "https://${module.gke.cluster_endpoint}"
    cluster_ca_certificate = base64decode(module.gke.cluster_ca_certificate)
    token                  = data.google_client_config.default.access_token
  }
}
```

### 11. Plan, revisar, apply

Salvar o plano em arquivo e aplicar *esse* arquivo é o que garante que o revisado é
exatamente o executado — `apply -auto-approve` aplica o que o Terraform recalcular
na hora.

```bash
terraform init
terraform plan -out=tfplan.bin
terraform show -json tfplan.bin | jq '.resource_changes | length'   # 83
terraform apply tfplan.bin
```

> **Tempos observados.** VPC, IAM, Pub/Sub, Firestore e Artifact Registry saem em
> segundos. O peering de Private Service Access, o GKE e as 3 instâncias Cloud SQL
> é que definem a duração total — na faixa de 25 a 40 minutos, em paralelo.

---

## Pipeline sem chave estática

### 12. Workload Identity Federation no lugar de uma chave JSON

O caminho comum é gerar uma chave de service account e colar como secret do GitHub.
Isso cria um segredo de **longa duração** — o alvo óbvio se o repositório vazar. A
federação OIDC troca o token do próprio workflow por um token temporário do GCP.

```hcl
resource "google_iam_workload_identity_pool_provider" "github" {
  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
  }
  # sem esta condição, QUALQUER repo do GitHub poderia tentar assumir a SA
  attribute_condition = "assertion.repository == \"mgm777/3-CICLO-POS-FIAP\""
  oidc { issuer_uri = "https://token.actions.githubusercontent.com" }
}
```

No workflow, basta `permissions: id-token: write` e a action oficial. A SA do CI
tem uma permissão só: `artifactregistry.writer` — ela publica imagem e nada mais.
Quem aplica no cluster é o ArgoCD.

### 13. Os gates de segurança, e onde eles cortam

`docker-build-push` declara `needs: [build-test, lint, security-scan]`. Uma CVE
crítica não impede só a *publicação* — a imagem sequer chega a ser construída.

| Estágio | Go | Python | Bloqueia em |
|---|---|---|---|
| Build & test | `go build`, `go test` | `compileall`, `pytest` | qualquer falha |
| Lint | `golangci-lint` | `flake8 E9,F63,F7,F82` | bug real |
| SAST | `gosec` | `bandit` | HIGH |
| SCA | `trivy fs --scanners vuln` | idem | CRITICAL |
| Container scan | `trivy image` | idem | CRITICAL |

> **Decisão de projeto.** Bloquear também em HIGH parece mais rigoroso, mas quebra
> a esteira em CVEs transitivos de imagem base que não têm correção publicada — e
> aí ninguém entrega nada. O corte fica em CRITICAL (que é o que o enunciado pede) e
> o HIGH é escaneado e impresso no log, visível sem travar.

### 14. GitOps: o CI não faz deploy

O último job reescreve a tag da imagem no manifesto e commita. Só isso. O ArgoCD
observa a pasta `gitops/` e sincroniza sozinho.

```bash
sed -i -E "s|(image: .*/${SERVICE}:).*|\1${NEW_TAG}|" "gitops/${SERVICE}/deployment.yaml"
git commit -m "chore(gitops): ${SERVICE} -> ${NEW_TAG}"
# outro serviço pode ter commitado enquanto este job rodava
for i in 1 2 3; do git pull --rebase origin main && git push origin main && exit 0; sleep 5; done
```

As Applications usam `selfHeal: true`: um `kubectl apply` feito à mão no cluster é
revertido automaticamente. É o que encerra, na prática, o problema dos deploys
manuais da máquina de cada dev.

---

## O que quebrou no caminho

**Todos os 5 workflows em `startup_failure`, sem log.**
Os workflows reutilizáveis declaram `permissions: contents: write` (o job de GitOps
precisa commitar). O repositório estava com *Workflow permissions* em read-only, e
o GitHub recusa o workflow antes de iniciar — sem produzir log de job, o que torna
o diagnóstico cego.
→ `gh api -X PUT repos/OWNER/REPO/actions/permissions/workflow -f default_workflow_permissions=write`

**`Unable to resolve action aquasecurity/trivy-action@0.29.0`.**
As tags daquele repositório são prefixadas com `v`. Depois de corrigir, a action
passou a falhar na própria instalação do binário do Trivy — falha de ferramenta de
terceiro, não achado de segurança.
→ Baixar o tarball do release oficial com versão fixa. O scan fica reproduzível e
independe do comportamento da action.

**Instalador do Trivy falhando em `/usr/local/bin`.**
O runner do GitHub não escreve nesse diretório sem `sudo`.
→ Instalar em `$HOME/.trivy-bin` e publicar o caminho com
`echo "$HOME/.trivy-bin" >> "$GITHUB_PATH"`. Atenção: `$GITHUB_PATH` só vale para
os steps **seguintes** — no próprio step de instalação, chame pelo caminho absoluto.

**Falsos positivos travando código correto.**
`B104` (bandit) acusa bind em `0.0.0.0` — que é exatamente o comportamento certo
dentro de um container, onde quem controla exposição é o Service. `G704` (gosec)
acusa SSRF em URLs que vêm de um ConfigMap interno, não de input de usuário.
→ Excluir por código específico, com o motivo escrito no próprio workflow. Exclusão
sem justificativa documentada vira dívida invisível.

**`SA1019`: exclusão de linter escondendo migração pendente.**
O `staticcheck` acusou que `cloud.google.com/go/pubsub` v1 está deprecado. A
primeira reação foi excluir o aviso — o que troca uma dívida por uma configuração.
→ Migrar de fato para `pubsub/v2` (`client.Topic()` → `client.Publisher()` com
`defer publisher.Stop()`), e devolver o linter ao conjunto padrão sem exceção.

**`terraform plan` funcionando, provider sem credencial.**
`gcloud auth login` tinha sido feito, mas o ADC não — são credenciais separadas.
→ `gcloud auth application-default login`.

**Pods em `CreateContainerConfigError`.**
O kubelet só consegue provar que o usuário não é root se o UID for numérico;
`USER appuser` no Dockerfile não basta.
→ `runAsUser: 1000` no `securityContext` do container.

---

## Custo e desmontagem

| Recurso | Configuração | US$/mês |
|---|---|---|
| GKE node pool | 2× `e2-standard-2` | ~97 |
| GKE management fee | zonal, primeiro cluster | 0 |
| Cloud SQL | 3× `db-f1-micro`, 10 GB | ~30 |
| Memorystore | BASIC, 1 GB | ~35 |
| Cloud NAT | 1 gateway | ~32 |
| Artifact Registry | < 10 GB | ~1 |
| Pub/Sub + Firestore | volume de demonstração | free tier |

Cluster zonal em vez de regional é a maior economia isolada: um terço do custo de
controle e criação bem mais rápida. Em produção seria regional.

```bash
# derruba tudo — o bucket de state sobrevive (force_destroy = false)
cd terraform && terraform destroy
```

---
## Apêndice — cada decisão, no trecho onde ela vive

O código do repositório não tem comentários: a explicação de cada escolha
está aqui, junto do trecho a que se refere. O texto diz *por quê*; o trecho
diz *onde*.

### Estado e bootstrap

Requisito de Estado (Fase 3): o terraform.tfstate NAO fica local. O bloco backend nao aceita variaveis — o bucket abaixo e criado pelo modulo terraform/bootstrap (rode-o primeiro). Se voce mudar o nome do projeto, ajuste aqui tambem.

`terraform/backend.tf`

```hcl
terraform {
  backend "gcs" {
    bucket = "fiap-3-508723-tfstate"
    prefix = "fase3/togglemaster"
  }
}
```

Bootstrap: cria o bucket GCS que guarda o terraform.tfstate remoto da infraestrutura principal. Este modulo e o unico com state LOCAL — nao da para guardar o state do bucket dentro do proprio bucket. Rode uma vez, depois use o bucket em ../backend.tf. terraform init && terraform apply -var project_id=fiap-3-508723

`terraform/bootstrap/main.tf`

```hcl
terraform {
  required_version = ">= 1.10"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

provider "google" {
    ...
```

Guarda o historico do state: permite voltar atras se um apply corromper o arquivo (equivalente ao versioning do bucket S3).

`terraform/bootstrap/main.tf`

```hcl
versioning {
  enabled = true
}

uniform_bucket_level_access = true
```

Bloqueia qualquer tentativa de tornar o state publico.

`terraform/bootstrap/main.tf`

```hcl
  public_access_prevention = "enforced"

  lifecycle_rule {
    condition {
      num_newer_versions = 20
    }
    action {
      type = "Delete"
    }
  }
}

    ...
```

### Rede

Permite que nodes sem IP externo alcancem APIs do Google (Artifact Registry, Cloud Logging) sem passar pela internet publica.

`terraform/modules/networking/main.tf`

```hcl
  private_ip_google_access = true

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = var.pods_cidr
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = var.services_cidr
  }
}
```

Cloud SQL e Memorystore precisam esperar o peering existir.

`terraform/modules/networking/outputs.tf`

```hcl
output "private_vpc_connection_id" {
  value = google_service_networking_connection.private_vpc_connection.id
}
```

### Cluster GKE

ClusterIP + port-forward basta para a demonstracao; trocar para LoadBalancer se quiser expor a UI publicamente.

`terraform/argocd.tf`

```hcl
set {
  name  = "server.service.type"
  value = "ClusterIP"
}
```

O repositorio GitOps e publico: o ArgoCD nao precisa de credencial de git.

`terraform/argocd.tf`

```hcl
  timeout = 900
}
```

Namespace onde os 5 microsservicos rodam. Criado aqui (e nao pelo ArgoCD) porque as KSAs com anotacao de Workload Identity precisam existir antes do primeiro sync.

`terraform/argocd.tf`

```hcl
resource "kubernetes_namespace" "togglemaster" {
  metadata {
    name = var.k8s_namespace
  }

  depends_on = [module.gke]
}
```

Uma KSA por servico, anotada com a GSA correspondente — completa o par de Workload Identity configurado no modulo iam.

`terraform/argocd.tf`

```hcl
resource "kubernetes_service_account" "app" {
  for_each = toset(local.services)

  metadata {
    name      = "${each.value}-ksa"
    namespace = kubernetes_namespace.togglemaster.metadata[0].name

    annotations = {
      "iam.gke.io/gcp-service-account" = module.iam.service_account_emails[each.value]
    }
  }
}
```

O node pool default e removido para que todo o pool gerenciado seja descrito em codigo (google_container_node_pool abaixo).

`terraform/modules/gke/main.tf`

```hcl
remove_default_node_pool = true
initial_node_count       = 1

ip_allocation_policy {
  cluster_secondary_range_name  = var.pods_range_name
  services_secondary_range_name = var.services_range_name
}
```

Workload Identity: os pods assumem Service Accounts do GCP sem nenhuma chave JSON montada no container. E a resposta direta ao problema "credenciais passadas em arquivos de texto sem seguranca" do enunciado.

`terraform/modules/gke/main.tf`

```hcl
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  release_channel {
    channel = "REGULAR"
  }

  deletion_protection = false
}

resource "google_container_node_pool" "primary_nodes" {
    ...
```

Obriga os pods a passarem pelo metadata server do GKE (Workload Identity) em vez de herdarem a SA do node.

`terraform/modules/gke/main.tf`

```hcl
workload_metadata_config {
  mode = "GKE_METADATA"
}

oauth_scopes = [
  "https://www.googleapis.com/auth/cloud-platform",
]

shielded_instance_config {
  enable_secure_boot          = true
  enable_integrity_monitoring = true
}
...
```

### Dados e mensageria

Senhas geradas pelo Terraform — nunca digitadas, nunca commitadas.

`terraform/modules/cloudsql/main.tf`

```hcl
resource "random_password" "db" {
  for_each = var.instances

  length  = 24
  special = false
}

resource "google_sql_database_instance" "postgres" {
  for_each = var.instances

  name             = "togglemaster-${each.key}-db"
  database_version = var.database_version
    ...
```

custo — ambiente de homologacao (ver README)

`terraform/modules/cloudsql/main.tf`

```hcl
availability_type = "ZONAL"
```

Sem IP publico: o banco so e alcancavel de dentro da VPC, via Private Service Access.

`terraform/modules/cloudsql/main.tf`

```hcl
    ipv4_enabled    = false
    private_network = var.network_id
  }

  backup_configuration {
    enabled = false
  }

  insights_config {
    query_insights_enabled = true
  }
}
  ...
```

Equivalente GCP da tabela DynamoDB ToggleMasterAnalytics: o analytics-service grava os eventos de avaliacao na colecao ToggleMasterAnalytics deste banco.

`terraform/modules/firestore/main.tf`

```hcl
resource "google_firestore_database" "analytics" {
  project     = var.project_id
  name        = var.database_name
  location_id = var.location_id
  type        = "FIRESTORE_NATIVE"

  deletion_policy = "DELETE"
}

output "database_name" {
  value = google_firestore_database.analytics.name
}
```

Equivalente GCP do ElastiCache: cache do evaluation-service. Tier BASIC (sem replica) — decisao de custo para ambiente de estudo.

`terraform/modules/memorystore/main.tf`

```hcl
resource "google_redis_instance" "cache" {
  name           = var.name
  tier           = "BASIC"
  memory_size_gb = var.memory_size_gb
  region         = var.region
  redis_version  = var.redis_version

  authorized_network = var.network_id
  connect_mode       = "PRIVATE_SERVICE_ACCESS"

  depends_on = [var.private_vpc_connection_id]
}
    ...
```

Equivalente GCP do SQS: o evaluation-service publica, o analytics-service consome.

`terraform/modules/messaging/main.tf`

```hcl
resource "google_pubsub_topic" "evaluation_events" {
  name = var.topic_name
}

resource "google_pubsub_topic" "dead_letter" {
  name = "${var.topic_name}-dlq"
}

resource "google_pubsub_subscription" "evaluation_events" {
  name  = var.subscription_name
  topic = google_pubsub_topic.evaluation_events.name

    ...
```

Mensagem que falha 5 vezes vai para a DLQ em vez de ficar em loop infinito ("poison pill").

`terraform/modules/messaging/main.tf`

```hcl
dead_letter_policy {
  dead_letter_topic     = google_pubsub_topic.dead_letter.id
  max_delivery_attempts = 5
}

retry_policy {
  minimum_backoff = "10s"
  maximum_backoff = "600s"
}

expiration_policy {
  ttl = "" # nunca expira
  ...
```

O service agent do Pub/Sub precisa poder publicar na DLQ e confirmar mensagens da subscription para que o dead_letter_policy funcione.

`terraform/modules/messaging/main.tf`

```hcl
data "google_project" "this" {}

locals {
  pubsub_agent = "serviceAccount:service-${data.google_project.this.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
}

resource "google_pubsub_topic_iam_member" "dlq_publisher" {
  topic  = google_pubsub_topic.dead_letter.name
  role   = "roles/pubsub.publisher"
  member = local.pubsub_agent
}

    ...
```

### Identidade e segredos

Sem esta condicao, qualquer repositorio do GitHub no mundo poderia tentar assumir a SA. Restringe a federacao a este repositorio.

`terraform/modules/cicd/main.tf`

```hcl
  attribute_condition = "assertion.repository == \"${var.github_repository}\""

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}
```

Permissao minima: empurrar imagem para o Artifact Registry. O deploy no cluster NAO passa por aqui — quem aplica no cluster e o ArgoCD (GitOps), entao o pipeline nao precisa de nenhuma credencial do Kubernetes.

`terraform/modules/cicd/main.tf`

```hcl
resource "google_project_iam_member" "ci_artifact_writer" {
  project = var.project_id
  role    = "roles/artifactregistry.writer"
  member  = "serviceAccount:${google_service_account.ci.email}"
}

resource "google_service_account_iam_member" "ci_workload_identity" {
  service_account_id = google_service_account.ci.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${var.github_repository}"
}

    ...
```

Uma GSA por servico: menor privilegio, sem SA compartilhada entre workloads.

`terraform/modules/iam/main.tf`

```hcl
resource "google_service_account" "app" {
  for_each = toset(var.services)

  account_id   = "${each.value}-gsa"
  display_name = "GSA do ${each.value} (ToggleMaster)"
}

resource "google_project_iam_member" "cloudsql_client" {
  for_each = toset(var.sql_services)

  project = var.project_id
  role    = "roles/cloudsql.client"
    ...
```

Cada servico le apenas o secret da sua propria DATABASE_URL.

`terraform/modules/iam/main.tf`

```hcl
resource "google_secret_manager_secret_iam_member" "database_url_accessor" {
  for_each = var.database_url_secret_ids

  project   = var.project_id
  secret_id = each.value
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.app[each.key].email}"
}
```

Cria os Secrets do Kubernetes que os Deployments consomem. Nenhuma credencial vem de arquivo de texto no repositorio: as DATABASE_URLs sao lidas do Secret Manager (criadas pelo Terraform, senhas geradas por random_password) e a API key do evaluation-service e mintada na hora pelo proprio auth-service. Uso: MASTER_KEY=$(openssl rand -hex 32) ./scripts/create-secrets.sh Guarde a MASTER_KEY: e ela que autoriza a criacao de novas API keys.

`scripts/create-secrets.sh`

```bash
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-fiap-3-508723}"
NAMESPACE="${NAMESPACE:-togglemaster}"
TF_DIR="$(cd "$(dirname "$0")/../terraform" && pwd)"

: "${MASTER_KEY:?defina MASTER_KEY antes de rodar (ex.: MASTER_KEY=\$(openssl rand -hex 32))}"

secret_value() {
  gcloud secrets versions access latest --secret="$1" --project="$PROJECT_ID"
}

    ...
```

O evaluation-service precisa de uma API key valida emitida pelo auth-service. Enquanto o auth-service nao estiver de pe, criamos o Secret so com o Redis para o pod conseguir subir; rode o script de novo depois para completar.

`scripts/create-secrets.sh`

```bash
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
    ...
```

### Registro de imagens e APIs

Database-per-service: 3 instancias Cloud SQL Postgres (equivalente as 3 instancias RDS pedidas no enunciado).

`terraform/main.tf`

```hcl
sql_instances = {
  "auth-service"      = { db_name = "auth_db", user_name = "auth_user" }
  "flag-service"      = { db_name = "flags_db", user_name = "flags_user" }
  "targeting-service" = { db_name = "targeting_db", user_name = "targeting_user" }
}

required_apis = [
  "compute.googleapis.com",
  "container.googleapis.com",
  "artifactregistry.googleapis.com",
  "sqladmin.googleapis.com",
  "redis.googleapis.com",
  ...
```

Retencao: mantem as 10 tags mais recentes; o resto e limpo automaticamente (equivalente a lifecycle policy do ECR).

`terraform/modules/artifact-registry/main.tf`

```hcl
  cleanup_policies {
    id     = "keep-recent"
    action = "KEEP"
    most_recent_versions {
      keep_count = 10
    }
  }
}

output "repository_urls" {
  value = {
    for k, v in google_artifact_registry_repository.service_repos :
    ...
```

Nao desabilita a API no destroy: desabilitar container.googleapis.com derruba clusters de outros ambientes no mesmo projeto.

`terraform/modules/project-services/main.tf`

```hcl
  disable_on_destroy = false
}

output "enabled" {
  description = "Usado como depends_on pelos demais modulos."
  value       = [for s in google_project_service.this : s.id]
}
```

Token de curta duração do usuário/SA autenticado no gcloud — nenhuma chave estática de service account é gravada em disco ou no state.

`terraform/versions.tf`

```hcl
data "google_client_config" "default" {}

provider "kubernetes" {
  host                   = "https://${module.gke.cluster_endpoint}"
  cluster_ca_certificate = base64decode(module.gke.cluster_ca_certificate)
  token                  = data.google_client_config.default.access_token
}

provider "helm" {
  kubernetes {
    host                   = "https://${module.gke.cluster_endpoint}"
    cluster_ca_certificate = base64decode(module.gke.cluster_ca_certificate)
    ...
```

### Pipeline de CI

permite disparar a mao durante a demonstracao

`.github/workflows/analytics-service.yml` _(repetido em 5 arquivos)_

```yaml
workflow_dispatch:
```

job gitops-update commita a nova tag neste repo

`.github/workflows/reusable-go-ci.yml` _(repetido em 2 arquivos)_

```yaml
contents: write
```

OIDC para o Workload Identity Federation do GCP

`.github/workflows/reusable-go-ci.yml` _(repetido em 2 arquivos)_

```yaml
id-token: write
```

SAST: analisa o codigo-fonte em busca de padroes inseguros. Bloqueia em severidade HIGH com confianca HIGH. Exclusoes documentadas: G104 - erro nao tratado (coberto pelo linter, nao e vulnerabilidade) G115 - conversao de inteiro; falso positivo em conversao de tamanho G704 - "SSRF": as URLs vem de ConfigMap interno, nao de input do usuario

`.github/workflows/reusable-go-ci.yml`

```yaml
- name: SAST - gosec (bloqueia em HIGH)
  working-directory: ${{ inputs.service_path }}
  run: |
    go install github.com/securego/gosec/v2/cmd/gosec@latest
    gosec -severity high -confidence high -exclude=G104,G115,G704 ./...

- name: SAST - gosec (relatorio completo, nao bloqueia)
  if: always()
  working-directory: ${{ inputs.service_path }}
  continue-on-error: true
  run: gosec ./...
```

SCA: analisa as dependencias declaradas no go.mod/go.sum. REGRA DE BLOQUEIO: qualquer CVE CRITICAL falha o pipeline aqui e o job docker-build-push (que depende deste) nem chega a rodar. Binario oficial em versao fixa: o resultado do scan nao muda porque uma action de terceiro mudou de comportamento.

`.github/workflows/reusable-go-ci.yml`

```yaml
  - name: Instala o Trivy
    run: |
      TRIVY_VERSION=0.74.0
      mkdir -p "$HOME/.trivy-bin"
      curl -sSfL -o /tmp/trivy.tar.gz \
        "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_Linux-64bit.tar.gz"
      tar -xzf /tmp/trivy.tar.gz -C "$HOME/.trivy-bin" trivy
      echo "$HOME/.trivy-bin" >> "$GITHUB_PATH"
      "$HOME/.trivy-bin/trivy" --version

  - name: SCA - Trivy filesystem (bloqueia em CRITICAL)
    run: |
...
```

Relatorio informativo de HIGH — visivel no log, sem quebrar o build.

`.github/workflows/reusable-go-ci.yml` _(repetido em 2 arquivos)_

```yaml
- name: SCA - Trivy filesystem (relatorio HIGH)
  if: always()
  continue-on-error: true
  run: |
    trivy fs --scanners vuln --severity HIGH --ignore-unfixed \
      --exit-code 0 --no-progress "${{ inputs.service_path }}"
```

Container Scan: a imagem final (base + libs do SO) tambem e auditada.

`.github/workflows/reusable-go-ci.yml` _(repetido em 2 arquivos)_

```yaml
  - name: Instala o Trivy
    run: |
      TRIVY_VERSION=0.74.0
      mkdir -p "$HOME/.trivy-bin"
      curl -sSfL -o /tmp/trivy.tar.gz \
        "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_Linux-64bit.tar.gz"
      tar -xzf /tmp/trivy.tar.gz -C "$HOME/.trivy-bin" trivy
      echo "$HOME/.trivy-bin" >> "$GITHUB_PATH"

  - name: Container Scan - Trivy image (bloqueia em CRITICAL)
    run: |
      trivy image --severity CRITICAL --ignore-unfixed --exit-code 1 --no-progress \
...
```

Autenticacao sem chave: troca o token OIDC do GitHub por um token de curta duracao do GCP (Workload Identity Federation).

`.github/workflows/reusable-go-ci.yml` _(repetido em 2 arquivos)_

```yaml
  - name: Autentica no GCP (OIDC / WIF)
    uses: google-github-actions/auth@v2
    with:
      workload_identity_provider: ${{ secrets.GCP_WIF_PROVIDER }}
      service_account: ${{ secrets.GCP_CI_SERVICE_ACCOUNT }}

  - name: Login no Artifact Registry
    run: gcloud auth configure-docker ${{ secrets.GCP_REGION }}-docker.pkg.dev --quiet

  - name: Push para o Artifact Registry
    run: |
      IMAGE_URI="${{ secrets.GCP_REGION }}-docker.pkg.dev/${{ secrets.GCP_PROJECT_ID }}/${{ inputs.service_name }}/${{ inputs.service_name }}:${{ steps.tag.outputs.image_tag }}"
...
```

Outro servico pode ter commitado enquanto este job rodava.

`.github/workflows/reusable-go-ci.yml` _(repetido em 2 arquivos)_

```yaml
for i in 1 2 3; do
  git pull --rebase origin main && git push origin main && exit 0
  sleep 5
done
exit 1
```

Gate que bloqueia: erros de sintaxe e bugs reais detectados pelo pyflakes (nome indefinido, import quebrado, comparacao invalida).

`.github/workflows/reusable-python-ci.yml`

```yaml
- name: flake8 — erros que quebram o build
  run: flake8 . --count --select=E9,F63,F7,F82 --show-source --statistics
```

Estilo (PEP 8) e reportado para leitura, sem travar a entrega de codigo herdado da Fase 2.

`.github/workflows/reusable-python-ci.yml`

```yaml
- name: flake8 — relatorio de estilo (nao bloqueia)
  continue-on-error: true
  run: flake8 . --count --max-line-length=120 --extend-ignore=E203,W503 --statistics
```

SAST: analisa o codigo-fonte em busca de padroes inseguros. Bloqueia em severidade HIGH (mesmo criterio do gosec no lado Go). B104 (bind em 0.0.0.0) e ignorado: em container isso e o comportamento correto — quem controla a exposicao e o Service.

`.github/workflows/reusable-python-ci.yml`

```yaml
- name: SAST - bandit (bloqueia em HIGH)
  working-directory: ${{ inputs.service_path }}
  run: |
    pip install bandit
    bandit -r . -lll -ii --skip B104 --exclude ./test_app.py

- name: SAST - bandit (relatorio MEDIUM, nao bloqueia)
  if: always()
  working-directory: ${{ inputs.service_path }}
  continue-on-error: true
  run: bandit -r . -ll --skip B104 --exclude ./test_app.py
```

SCA: analisa as dependencias do requirements.txt. REGRA DE BLOQUEIO: qualquer CVE CRITICAL falha o pipeline aqui e o job docker-build-push (que depende deste) nem chega a rodar. Binario oficial em versao fixa: o resultado do scan nao muda porque uma action de terceiro mudou de comportamento.

`.github/workflows/reusable-python-ci.yml`

```yaml
  - name: Instala o Trivy
    run: |
      TRIVY_VERSION=0.74.0
      mkdir -p "$HOME/.trivy-bin"
      curl -sSfL -o /tmp/trivy.tar.gz \
        "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_Linux-64bit.tar.gz"
      tar -xzf /tmp/trivy.tar.gz -C "$HOME/.trivy-bin" trivy
      echo "$HOME/.trivy-bin" >> "$GITHUB_PATH"
      "$HOME/.trivy-bin/trivy" --version

  - name: SCA - Trivy filesystem (bloqueia em CRITICAL)
    run: |
...
```

### Imagens Docker

Aplica os patches de seguranca do SO na imagem final. O scan de container do pipeline pegou 3 CVEs CRITICAL em perl-base vindas da imagem base do Debian (CVE-2026-8376, CVE-2026-13221, CVE-2026-42496) — todas com correcao publicada. Sem este upgrade, a regra de bloqueio impede a publicacao.

`services/analytics-service/Dockerfile` _(repetido em 3 arquivos)_

```
RUN apt-get update && \
    apt-get upgrade -y --no-install-recommends && \
    rm -rf /var/lib/apt/lists/*

RUN useradd -u 1000 -m appuser
WORKDIR /app

COPY --from=builder /venv /venv
COPY . .

ENV PATH="/venv/bin:$PATH"

    ...
```

### Manifestos e ArgoCD

KSA vinculada a uma Google Service Account por Workload Identity: o pod autentica no GCP sem nenhuma chave JSON montada.

`gitops/analytics-service/deployment.yaml` _(repetido em 5 arquivos)_

```yaml
serviceAccountName: analytics-service-ksa
containers:
  - name: analytics-service
```

A tag abaixo e reescrita automaticamente pelo job gitops-update do pipeline de CI. Nao edite a mao.

`gitops/analytics-service/deployment.yaml` _(repetido em 5 arquivos)_

```yaml
      image: us-central1-docker.pkg.dev/fiap-3-508723/analytics-service/analytics-service:v1.0.0-35de366
      ports:
        - containerPort: 8005
      env:
        - name: PORT
          value: "8005"
        - name: GCP_PROJECT_ID
          valueFrom:
            configMapKeyRef:
              name: togglemaster-config
              key: GCP_PROJECT_ID
        - name: PUBSUB_SUBSCRIPTION_ID
...
```

O kubelet so consegue provar que o usuario nao e root se o UID for numerico; os Dockerfiles criam appuser com uid 1000.

`gitops/analytics-service/deployment.yaml` _(repetido em 5 arquivos)_

```yaml
runAsUser: 1000
capabilities:
  drop: ["ALL"]
```

Sync automatico: o ArgoCD aplica sozinho o que for commitado em gitops/analytics-service.

`gitops/argocd-apps/analytics-service-app.yaml`

```yaml
automated:
  prune: true    # remove do cluster o que sumir do git
  selfHeal: true # desfaz alteracao feita direto no cluster (kubectl apply manual)
syncOptions:
  - CreateNamespace=true
retry:
  limit: 5
  backoff:
    duration: 10s
    maxDuration: 3m
    factor: 2
```

remove do cluster o que sumir do git

`gitops/argocd-apps/analytics-service-app.yaml` _(repetido em 6 arquivos)_

```yaml
prune: true
```

desfaz alteracao feita direto no cluster (kubectl apply manual)

`gitops/argocd-apps/analytics-service-app.yaml` _(repetido em 6 arquivos)_

```yaml
selfHeal: true
```

Sync automatico: o ArgoCD aplica sozinho o que for commitado em gitops/auth-service.

`gitops/argocd-apps/auth-service-app.yaml`

```yaml
automated:
  prune: true    # remove do cluster o que sumir do git
  selfHeal: true # desfaz alteracao feita direto no cluster (kubectl apply manual)
syncOptions:
  - CreateNamespace=true
retry:
  limit: 5
  backoff:
    duration: 10s
    maxDuration: 3m
    factor: 2
```

Sync automatico: o ArgoCD aplica sozinho o que for commitado em gitops/evaluation-service.

`gitops/argocd-apps/evaluation-service-app.yaml`

```yaml
automated:
  prune: true    # remove do cluster o que sumir do git
  selfHeal: true # desfaz alteracao feita direto no cluster (kubectl apply manual)
syncOptions:
  - CreateNamespace=true
retry:
  limit: 5
  backoff:
    duration: 10s
    maxDuration: 3m
    factor: 2
```

Sync automatico: o ArgoCD aplica sozinho o que for commitado em gitops/flag-service.

`gitops/argocd-apps/flag-service-app.yaml`

```yaml
automated:
  prune: true    # remove do cluster o que sumir do git
  selfHeal: true # desfaz alteracao feita direto no cluster (kubectl apply manual)
syncOptions:
  - CreateNamespace=true
retry:
  limit: 5
  backoff:
    duration: 10s
    maxDuration: 3m
    factor: 2
```

Sync automatico: o ArgoCD aplica sozinho o que for commitado em gitops/platform.

`gitops/argocd-apps/platform-app.yaml`

```yaml
automated:
  prune: true    # remove do cluster o que sumir do git
  selfHeal: true # desfaz alteracao feita direto no cluster (kubectl apply manual)
syncOptions:
  - CreateNamespace=true
retry:
  limit: 5
  backoff:
    duration: 10s
    maxDuration: 3m
    factor: 2
```

Sync automatico: o ArgoCD aplica sozinho o que for commitado em gitops/targeting-service.

`gitops/argocd-apps/targeting-service-app.yaml`

```yaml
automated:
  prune: true    # remove do cluster o que sumir do git
  selfHeal: true # desfaz alteracao feita direto no cluster (kubectl apply manual)
syncOptions:
  - CreateNamespace=true
retry:
  limit: 5
  backoff:
    duration: 10s
    maxDuration: 3m
    factor: 2
```

### Higiene do repositório

Credenciais — nunca versionar

`.gitignore`

```
*.json.key
sa-key*.json
*-secret.yaml
.env
.env.*
!.env.example
```
