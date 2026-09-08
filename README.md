# volta-devops

Repositório central de infraestrutura, CI/CD e manifestos do projeto **Volta** —
solução para descarte de resíduos em empresas.

## O que mora aqui

| Diretório | Conteúdo |
|---|---|
| `.github/workflows/` | Reusable workflows consumidos pelos repositórios de aplicação |
| `kubernetes/` | Manifestos Kustomize (`base/` + `overlays/qa` e `overlays/prod`) |
| `scripts/` | Provisionamento do cluster, aplicação de manifestos e rollback |
| `docs/` | Documentação de arquitetura e decisões |

## Arquitetura em uma tela

```text
Código → CI → imagem no GHCR (<env>-<sha>) → repository_dispatch
                                                    │
                                     DevOps: kustomize edit set image + commit
                                                    │
                                     SSH → kubectl apply -k → k3s (EC2)
```

| Peça | Escolha |
|---|---|
| Orquestrador | k3s single-node em EC2 t3.medium (AWS Academy Learner Lab) |
| Ambientes | namespaces `volta-qa` (branch `develop`) e `volta-prod` (branch `main`) |
| Registry | GHCR, imagens públicas |
| Ingress | Traefik (embutido no k3s) + `sslip.io` |
| Postgres | Neon, com branching por ambiente |
| MongoDB | MongoDB Atlas |
| Objetos | S3 via presigned URL assinada pela API |
| Website | Vercel |

## Workflows reutilizáveis

| Workflow | Função |
|---|---|
| `reusable-validate-pr.yaml` | Valida nome da branch, base do PR e título em Conventional Commits |
| `reusable-docker-build-push.yaml` | Build, push no GHCR e `repository_dispatch` para este repositório |
| `ghcr-cleanup.yaml` | Limpeza mensal de versões sem tag |
| `ec2-power.yaml` | Liga, desliga e inspeciona a EC2 do cluster (`workflow_dispatch`) |

Uso a partir de um repositório de aplicação:

```yaml
jobs:
  build:
    uses: app-volta/volta-devops/.github/workflows/reusable-docker-build-push.yaml@v1
    with:
      image-name: api
      environment: qa
    secrets:
      devops-dispatch-token: ${{ secrets.DEVOPS_DISPATCH_TOKEN }}
```

## Operar o cluster

A máquina é criada **uma única vez**, rodando o script abaixo localmente (fica
versionado aqui para documentar exatamente como o cluster foi provisionado):

```bash
./scripts/provision-ec2-k3s.sh    # cria o cluster do zero (idempotente)
```

Ligar, desligar e verificar o estado, no dia a dia, é só pela interface do
GitHub, no workflow **"Ligar e desligar o cluster"**
(`Actions` → escolher `start`, `stop` ou `status` → *Run workflow*).

A instância para sozinha após ~15 min sem tráfego de rede. Passo a passo
completo e diagnóstico em [`docs/06-cluster-k3s.md`](docs/06-cluster-k3s.md).

## Documentação

- [`docs/01-arquitetura-cicd.md`](docs/01-arquitetura-cicd.md) — arquitetura de
  CI/CD completa: branches, rulesets, ambientes, GHCR, deploy, secrets e as
  comparações que sustentam cada decisão.
- [`docs/06-cluster-k3s.md`](docs/06-cluster-k3s.md) — runbook do cluster:
  provisionamento, operação, custo e diagnóstico.
