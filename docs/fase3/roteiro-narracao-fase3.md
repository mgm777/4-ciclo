# Roteiro de narração — vídeo de demonstração

Vídeo montado: `~/Videos/tech-challenge-fase3/tech-challenge-fase3-COMPLETO.mp4`
(6min30, 1920×1080, sem áudio — grave a narração por cima).

Os segmentos também estão separados, caso queira regravar ou reordenar algum:

| Arquivo | Duração | Entra em |
|---|---|---|
| `1-iac.mp4` | 1:46 | 0:00 |
| `2-devsecops.mp4` | 0:57 | 1:46 |
| `3-gitops.mp4` | 0:50 | 2:43 |
| `4-argocd-selfheal.mp4` | 1:29 | 3:33 |
| `5-argocd-ui.mp4` | 1:28 | 5:02 |

> Dica: as pausas entre comandos foram calibradas para dar tempo de falar. Se
> precisar de mais fôlego em algum ponto, congele o frame por 2–3s na edição.

---

## Abertura — 0:00 a 0:12

> "Boa noite. Esse é o Tech Challenge da Fase 3 do ToggleMaster. A Fase 2 desse
> projeto foi entregue no Google Cloud, então a Fase 3 é a continuação daquele
> mesmo ambiente: toda a infraestrutura em Terraform, pipeline com DevSecOps no
> GitHub Actions e deploy por GitOps com ArgoCD, num cluster GKE."

## 1. Infraestrutura como código — 0:12 a 1:46

**0:12 — os módulos**
> "A infra está inteira em Terraform, quebrada em dez módulos: rede, cluster,
> banco, cache, mensageria, registro de imagem, IAM e a federação do CI. Cada um
> isolado, com suas próprias variáveis e saídas."

**0:30 — o backend remoto**
> "O requisito de estado da fase: o `tfstate` não fica local. Ele mora num bucket
> versionado no Cloud Storage. Esse bucket é criado por um projeto Terraform
> separado — o bootstrap — porque ele não pode guardar o próprio estado dentro de
> si mesmo."

**0:50 — os recursos**
> "Hoje o Terraform gerencia oitenta e cinco recursos. Na lista dá pra ver os
> módulos aparecendo: artifact registry, o pool de identidade do CI, os secrets
> do Cloud SQL, as service accounts."

**1:10 — o plan**
> "E o ambiente está convergido: o `plan` não encontra nenhuma diferença entre o
> código e o que está na nuvem. É a definição de infraestrutura imutável — se não
> está no código, não existe."

**1:25 — os recursos reais no GCP**
> "Isso não é teoria: o cluster GKE com dois nós, as três instâncias de Cloud SQL
> Postgres — uma por serviço —, o Memorystore Redis e os cinco repositórios do
> Artifact Registry. Tudo criado pelo `apply`, nada pelo console."

## 2. Pipeline DevSecOps — 1:46 a 2:43

**1:46 — o gate**
> "Agora o pipeline. O job que constrói e publica a imagem depende dos três
> anteriores: build e teste, lint, e o scan de segurança. Se qualquer um falhar,
> a imagem nem chega a ser construída."

**2:00 — a regra de bloqueio**
> "Essa é a regra de bloqueio: o Trivy roda em modo filesystem nas dependências e
> em modo image na imagem final. Qualquer CVE crítica derruba o pipeline. As de
> severidade alta são escaneadas e reportadas no log, sem travar a entrega."

**2:15 — os pipelines verdes**
> "Os cinco microsserviços, todos passando."

**2:25 — e aqui está o ponto**
> "E aqui está o ponto mais importante dessa entrega. O enunciado pede pra inserir
> uma vulnerabilidade proposital e mostrar o pipeline falhando. **Não foi
> preciso.** O código herdado da Fase 2 já tinha as suas: são vinte e seis
> execuções bloqueadas no histórico. O pipeline barrou seis CVEs críticas reais —
> uma delas exatamente no cenário do enunciado: uma biblioteca Go, o gRPC, numa
> versão com falha crítica conhecida."

> "Além dessa, uma na biblioteca padrão do Go, no `crypto/tls`, que exigiu subir
> o toolchain da versão 1.21 pra 1.25; e três no `perl-base` que vinham da imagem
> base do Debian, corrigidas aplicando os patches do sistema na imagem final.
> Todas estão documentadas no relatório, com o commit da correção."

## 3. GitOps — 2:43 a 3:33

**2:43 — o pipeline não faz deploy**
> "Aqui está a mudança de paradigma da fase. O último job do pipeline **não roda
> `kubectl apply`**. Ele só reescreve a tag da imagem no manifesto e faz commit.
> O pipeline não tem nenhuma credencial do Kubernetes."

**3:00 — os commits do robô**
> "Esses são os commits feitos pelo próprio CI. Cada vez que uma imagem é
> publicada, o robô commita a tag nova no diretório `gitops`."

**3:15 — o diff e a imagem**
> "No diff dá pra ver só a linha da imagem mudando, com o hash do commit. E a
> imagem correspondente está publicada no Artifact Registry, com essa mesma tag."

## 4. ArgoCD e self-heal — 3:33 a 5:02

**3:33 — os Applications**
> "No cluster, o ArgoCD gerencia seis Applications: os cinco microsserviços mais
> um de plataforma, que carrega o ConfigMap compartilhado. Todos sincronizados e
> saudáveis."

**3:50 — os pods**
> "E os pods rodando no namespace `togglemaster`."

**4:05 — a prova**
> "Agora a prova de que o problema dos deploys manuais acabou. Vou apagar um
> Deployment na mão, exatamente como um desenvolvedor faria da máquina dele."

**4:20 — sumiu**
> "O `flag-service` sumiu do cluster."

**4:35 — e volta**
> "O ArgoCD detecta que o cluster divergiu do repositório e recria sozinho. Isso é
> o `selfHeal`. Alteração feita fora do Git não sobrevive — a única forma de
> mudar o cluster é commitando."

**4:50**
> "E tudo volta pra sincronizado e saudável."

## 5. Interface do ArgoCD — 5:02 a 6:30

**5:02 — a tela**
> "Na interface, os seis Applications. Cada card mostra o repositório de origem, o
> caminho dentro dele, o namespace de destino e o horário do último sync."

**5:25 — os contadores**
> "Na lateral: seis sincronizados, seis saudáveis, zero fora de sincronia."

**5:45 — a árvore de recursos**
> "Entrando num serviço, a árvore de recursos que o ArgoCD gerencia: o
> Application, o Deployment, o ReplicaSet e os pods — com a origem de cada um
> rastreada até o commit."

**6:15 — fechamento**
> "Resumindo: oitenta e cinco recursos no Google Cloud, todos em código, com
> estado remoto. Cinco pipelines com SAST, SCA e scan de container, que já
> barraram seis vulnerabilidades críticas reais antes de irem pra produção.
> Nenhuma chave estática em lugar nenhum — os pods usam Workload Identity e o CI
> usa federação OIDC. E o deploy inteiro por GitOps, com o cluster se corrigindo
> sozinho. Obrigado."

---

## Checklist antes de enviar

- [ ] RM preenchido no `RELATORIO.md`
- [ ] Print da estimativa de custos no `RELATORIO.md`
- [ ] Link do vídeo no `RELATORIO.md`
- [ ] `terraform destroy` depois da correção da nota
