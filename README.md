# volta-devops

Repositório de infraestrutura e automação do projeto **Volta**, uma solução para
descarte de resíduos em empresas.

Aqui ficam o que faz o projeto **funcionar fora do código das aplicações**: as
pipelines de build e deploy (GitHub Actions), os manifestos do Kubernetes, os
scripts do servidor e a documentação.

## O que tem aqui

| Pasta | Conteúdo |
|---|---|
| `.github/workflows/` | pipelines de CI/CD, usadas pelos repositórios das aplicações |
| `docker-compose/` | Ambiente local com Docker ([como usar](docker-compose/README.md)) |
| `kubernetes/` | Arquivos do cluster: `base/` + `overlays/qa` e `overlays/prod` |
| `scripts/` | Provisionamento da Cloud, rollback e renovação de credenciais |
| `docs/` | Documentação completa |

## Como o projeto funciona

```text
Código → CI → imagem no GHCR (<ambiente>-<sha>) → aviso ao DevOps
                                                       │
                                 troca a versão da imagem nos manifestos
                                                       │
                                 SSH → kubectl apply → k3s (EC2)
```

| Peça | O que usamos |
|---|---|
| Servidor | k3s (Kubernetes leve) em uma EC2 t3.medium (AWS Academy Learner Lab) |
| Ambientes | `volta-qa` (branch `develop`) e `volta-prod` (branch `main`) |
| Imagens Docker | GHCR, públicas |
| Entrada de tráfego | Traefik (já vem no k3s) + `sslip.io` |
| Banco relacional | Postgres no Neon, com uma branch por ambiente |
| Banco de documentos | MongoDB Atlas |
| Fotos | S3, com URL assinada pela API |
| Website | Vercel |

## Por onde começar

| Quero... | Leia |
|---|---|
| Entender a arquitetura e as decisões | [`docs/01-arquitetura-cicd.md`](docs/01-arquitetura-cicd.md) |
| Saber o que muda entre QA e produção | [`docs/02-ambientes.md`](docs/02-ambientes.md) |
| Saber onde guardar senhas e tokens | [`docs/03-secrets.md`](docs/03-secrets.md) |
| Fazer deploy, rollback ou investigar um erro | [`docs/04-runbook-deploy.md`](docs/04-runbook-deploy.md) |
| Criar branch, commit e Pull Request | [`docs/05-padroes-git.md`](docs/05-padroes-git.md) |
| Criar ou operar o cluster | [`docs/06-cluster-k3s.md`](docs/06-cluster-k3s.md) |
| Configurar o Website na Vercel | [`docs/07-vercel-website.md`](docs/07-vercel-website.md) |
| Rodar o backend na minha máquina | [`docker-compose/README.md`](docker-compose/README.md) |

## Esteiras (workflows)

| Workflow | O que faz |
|---|---|
| `reusable-validate-pr.yaml` | Confere nome da branch, destino do PR e título (Conventional Commits) |
| `reusable-docker-build-push.yaml` | Gera a imagem, publica no GHCR e avisa este repositório |
| `reusable-k3s-deploy.yaml` | Aplica a nova versão no cluster e espera ficar saudável |
| `dispatch-deploy.yaml` | Recebe o aviso de imagem nova (ou um disparo manual) e inicia o deploy |
| `ec2-power.yaml` | Liga, desliga e mostra o estado da EC2 |
| `ghcr-cleanup.yaml` | Limpeza mensal de versões antigas e sem tag no GHCR |

Nome de branch aceito: `^(feat|fix|refactor|chore|test|docs)/SCRUM-[0-9]{1,4}$`
(exemplo: `feat/SCRUM-1858`). Detalhes em
[`docs/05-padroes-git.md`](docs/05-padroes-git.md).

### Usar a pipeline em outro repositório

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

O token `DEVOPS_DISPATCH_TOKEN` é explicado em
[`docs/03-secrets.md`](docs/03-secrets.md).

## Uso no dia a dia

### Ligar, desligar e ver o estado do cluster

Pelo GitHub, sem precisar de terminal:

**Actions → "Ligar e desligar o cluster" → Run workflow → `start`, `stop` ou `status`**

A máquina desliga sozinha depois de ~15 minutos sem tráfego de rede.

### Criar o cluster (só uma vez)

```bash
./scripts/provision-ec2-k3s.sh
```

O script pode ser rodado de novo sem problemas: ele reaproveita o que já existe.
Passo a passo em [`docs/06-cluster-k3s.md`](docs/06-cluster-k3s.md).

### Renovar a sessão do Learner Lab

A sessão da AWS Academy expira a cada ~4 horas. Cole o bloco de
**AWS Details → AWS CLI** neste script:

```bash
./scripts/update-aws-session.sh          # atualiza ~/.aws/credentials
./scripts/update-aws-session.sh --gh     # também atualiza os secrets do GitHub
```

### Voltar uma versão

```bash
./scripts/rollback.sh prod api                 # volta uma revisão
./scripts/rollback.sh prod api prod-a1b2c3d    # volta para uma tag específica
```

Outras opções em [`docs/04-runbook-deploy.md`](docs/04-runbook-deploy.md).

## HTTPS no QA

O QA está sendo preparado para responder em
`https://<serviço>.qa.<EIP>.sslip.io`. O certificado é do Let's Encrypt, emitido
pelo cert-manager, e o deploy instala e valida tudo sozinho. É preciso que a
variável `SSH_HOST` esteja definida no repositório.

Essa configuração **ainda precisa ser publicada e validada no cluster**. O
chatbot de QA fica com `replicas=0` por padrão. Para validar com o HTTPS, use a
opção `qa-smoke` do workflow **Deploy**: ela liga uma réplica, testa
`GET /health` e volta para zero. Esse teste não substitui a validação de sessão
e chat pelo app mobile. Detalhes em
[`docs/04-runbook-deploy.md`](docs/04-runbook-deploy.md#testar-o-chatbot-em-qa-qa-smoke).
