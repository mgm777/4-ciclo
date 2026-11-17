# Tech Challenge Fase 3 — ToggleMaster no Google Cloud

Automação completa da infraestrutura e do ciclo de vida dos 5 microsserviços do
ToggleMaster (`auth`, `flag`, `targeting`, `evaluation`, `analytics`) usando
**IaC (Terraform)**, **CI/CD com DevSecOps (GitHub Actions)** e **GitOps
(ArgoCD)** em um cluster **GKE**.

| Enunciado (AWS) | Implementado (GCP) |
|---|---|
| VPC, Subnets, IGW, Route Tables | VPC customizada, Subnet com ranges secundários, Cloud Router + Cloud NAT |
| Cluster EKS + Node Groups | **GKE** zonal + Node Pool gerenciado com autoscaling |
| 3 instâncias RDS PostgreSQL | **3 instâncias Cloud SQL** PostgreSQL 15 (uma por serviço, IP privado) |
| 1 cluster ElastiCache (Redis) | **Memorystore for Redis** 7.0 (tier BASIC) |
| 1 tabela DynamoDB `ToggleMasterAnalytics` | **Firestore** (Native) — coleção `ToggleMasterAnalytics` |
| 1 fila SQS | **Pub/Sub** — tópico `evaluation-events` + subscription e DLQ |
| 5 repositórios ECR | **5 repositórios no Artifact Registry** |
| Backend remoto em bucket S3 | **Backend remoto em bucket GCS** (versionado) |

## Arquitetura do repositório

```
services/           código dos 5 microsserviços (Go e Python)
terraform/          toda a infraestrutura como código, em módulos
  bootstrap/        cria o bucket GCS do state remoto (rodar uma vez)
  modules/          networking, gke, cloudsql, memorystore, messaging,
                    firestore, artifact-registry, iam, cicd, project-services
gitops/             manifestos Kubernetes que o ArgoCD sincroniza
  argocd-apps/      as Applications do ArgoCD (uma por serviço + platform)
.github/workflows/  pipelines de CI com os estágios de DevSecOps
scripts/            bootstrap dos Secrets a partir do Secret Manager
```

- **auth-service** (Go, `:8001`) — Cloud SQL próprio. Emite as API keys.
- **flag-service** (Python/Flask, `:8002`) — Cloud SQL próprio.
- **targeting-service** (Python/Flask, `:8003`) — Cloud SQL próprio.
- **evaluation-service** (Go, `:8004`) — Memorystore + publica no Pub/Sub.
- **analytics-service** (Python/Flask, `:8005`) — consome o Pub/Sub e grava no Firestore.

## Como as três dores do enunciado foram resolvidas

| Dor | Resposta |
|---|---|
| "Desenvolvedores rodando `kubectl apply` da máquina local" | O pipeline **não tem credencial de Kubernetes**. Ele só commita a nova tag em `gitops/`; quem aplica no cluster é o **ArgoCD**, com `selfHeal: true` (alteração manual no cluster é revertida sozinha). |
| "Credenciais do banco em arquivos de texto sem segurança" | As senhas são geradas por `random_password`, nunca digitadas nem commitadas, e ficam no **Secret Manager**. Os pods acessam o GCP por **Workload Identity** — nenhuma chave JSON dentro de container. O CI autentica por **Workload Identity Federation (OIDC)** — nenhuma chave de service account como secret do GitHub. |
| "Vulnerabilidade em biblioteca Go foi para produção" | Todo push/PR roda **SAST** (gosec / bandit), **SCA** (Trivy filesystem) e **Container Scan** (Trivy image). Qualquer CVE **CRITICAL** falha o job `security-scan`, e `docker-build-push` depende dele — a imagem nem chega a ser construída. |
| "Recriar homologação leva dias" | `terraform apply` recria tudo do zero, com o state versionado em bucket GCS. |

## Passo a passo

### 1. Pré-requisitos

```bash
gcloud auth login --update-adc
gcloud config set project fiap-3-508723
```

### 2. Bootstrap do backend remoto (uma única vez)

```bash
cd terraform/bootstrap
terraform init
terraform apply -var project_id=fiap-3-508723
# anote o output bucket_name e confira terraform/backend.tf
```

### 3. Infraestrutura principal

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # ajuste project_id e github_repository
terraform init
terraform plan
terraform apply
```

Provisiona VPC, GKE, 3 Cloud SQL, Memorystore, Firestore, Pub/Sub, 5
repositórios no Artifact Registry, as service accounts com Workload Identity,
a federação OIDC do GitHub Actions e instala o **ArgoCD** no cluster.

### 4. Apontar o kubectl para o cluster

```bash
$(terraform output -raw kubectl_config_command)
```

### 5. Criar os Secrets das aplicações

```bash
MASTER_KEY=$(openssl rand -hex 32) ./scripts/create-secrets.sh
```

### 6. Registrar as Applications do ArgoCD

```bash
kubectl apply -f gitops/argocd-apps/
kubectl get applications -n argocd
```

### 7. Acessar a UI do ArgoCD

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:443
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d; echo
# usuário admin, senha acima — https://localhost:8080
```

## Secrets necessários no GitHub

`Settings → Secrets and variables → Actions`:

| Secret | De onde vem |
|---|---|
| `GCP_WIF_PROVIDER` | `terraform output -raw github_secret_GCP_WIF_PROVIDER` |
| `GCP_CI_SERVICE_ACCOUNT` | `terraform output -raw github_secret_GCP_CI_SERVICE_ACCOUNT` |
| `GCP_PROJECT_ID` | `fiap-3-508723` |
| `GCP_REGION` | `us-central1` |

Não existe `GCP_SA_KEY`: a autenticação é federada por OIDC, sem chave estática.

Confirme também que *Settings → Actions → General → Workflow permissions* está
em **Read and write permissions** — o job `gitops-update` precisa commitar.

## Pipeline de CI/CD

Cada serviço tem seu workflow (`.github/workflows/<serviço>.yml`), disparado só
quando `services/<serviço>/**` muda, chamando um workflow reutilizável
(`reusable-go-ci.yml` ou `reusable-python-ci.yml`):

1. **Build & Unit Test** — compila e roda os testes.
2. **Linter/Static Analysis** — `golangci-lint` / `flake8`.
3. **Security Scan (SAST & SCA)** — `gosec`/`bandit` + `trivy fs`.
   **Regra de bloqueio:** CVE `CRITICAL` falha o pipeline; `HIGH` é reportado no log.
4. **Docker Build & Push** — só em push na `main`: build, `trivy image`
   (bloqueia em CRITICAL), autentica por OIDC e publica no Artifact Registry
   com a tag `v1.0.0-<commit-sha>`.
5. **GitOps update** — reescreve a tag em `gitops/<serviço>/deployment.yaml` e
   commita. O ArgoCD detecta e sincroniza sozinho.

### Como demonstrar o bloqueio de segurança

Adicione uma dependência com CVE crítica conhecida em um serviço Python
(ex.: `PyYAML==5.3.1`, CVE-2020-14343) e abra um PR: o job `security-scan`
falha no Trivy e o `docker-build-push` nem inicia. Reverta o commit e mostre o
pipeline verde.

## Decisões e trade-offs

- **Cluster GKE zonal** em vez de regional: cria mais rápido e custa ~1/3 —
  aceitável para homologação, seria regional em produção.
- **Cloud SQL `db-f1-micro`, sem HA e sem backup**: decisão de custo do ambiente
  de estudo.
- **Memorystore tier BASIC** (sem réplica): mesmo motivo.
- **Trivy + gosec/bandit em vez de SonarCloud**: sem dependência de conta
  externa, roda inteiramente dentro do GitHub Actions.
- **Bloqueio apenas em CRITICAL**: o enunciado pede exatamente isso; HIGH fica
  visível no log sem travar o fluxo de entrega.
- **Workload Identity Federation em vez de chave de service account**: elimina
  o segredo de longa duração que seria o alvo óbvio em um vazamento do repo.
- **Namespace e KSAs criados pelo Terraform**, não pelo ArgoCD: as anotações de
  Workload Identity precisam existir antes do primeiro sync dos Deployments.
