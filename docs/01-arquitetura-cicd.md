# Arquitetura de CI/CD: Projeto Volta

> Repositório: `app-volta/volta-devops` · Caminho: `docs/01-arquitetura-cicd.md`
> Versão 5: texto simplificado. Reflete a migração do Render para Kubernetes (k3s
> em uma EC2 do AWS Academy Learner Lab).

Este documento explica **como o projeto é construído e publicado, e por que cada
escolha foi feita**. Para o passo a passo do dia a dia, veja:

| Preciso de... | Documento |
|---|---|
| Diferenças entre QA e produção | [`02-ambientes.md`](02-ambientes.md) |
| Onde guardar senhas e tokens | [`03-secrets.md`](03-secrets.md) |
| Fazer deploy ou rollback | [`04-runbook-deploy.md`](04-runbook-deploy.md) |
| Regras de branch, commit e PR | [`05-padroes-git.md`](05-padroes-git.md) |
| Operar o cluster | [`06-cluster-k3s.md`](06-cluster-k3s.md) |
| Configurar o Website | [`07-vercel-website.md`](07-vercel-website.md) |

---

## Glossário rápido

| Termo | Significa |
|---|---|
| **CI** | Integração contínua: testar o código automaticamente a cada mudança |
| **CD** | Entrega contínua: publicar automaticamente o que passou nos testes |
| **GHCR** | Registro de imagens Docker do GitHub |
| **Imagem** | Pacote com a aplicação pronta para rodar |
| **k3s** | Versão leve do Kubernetes |
| **Namespace** | "Pasta" dentro do Kubernetes. Usamos uma por ambiente |
| **Kustomize** | Ferramenta que monta os manifestos do Kubernetes a partir de uma base e de ajustes por ambiente |
| **Reusable workflow** | Esteira do GitHub Actions que outros repositórios podem chamar |
| **Ruleset** | Regras de proteção das branches (exigir aprovação, exigir testes) |
| **Smoke test** | Teste rápido para ver se o serviço respondeu depois do deploy |
| **Rollback** | Voltar para uma versão anterior |

---

## Decisões principais

| Decisão | Consequência |
|---|---|
| **Todos os repositórios são públicos** | Proteção de branch, Environments e CODEOWNERS ficam disponíveis. Minutos de Actions são ilimitados |
| **Regras de proteção na organização**, com mínimo de 1 aprovação | Uma configuração vale para todos os repositórios (exceto o `volta-landing-page`) |
| **Imagens do GHCR públicas** | Armazenamento gratuito. O cluster e o Compose baixam sem login |
| **API e Chatbot no k3s** (EC2 t3.medium); **Website na Vercel** | Kubernetes é exigido pela disciplina. O front não gasta crédito AWS |
| **Postgres no Neon**, **MongoDB no Atlas** | Bancos gerenciados fora do cluster, com isolamento por ambiente |
| **Deploy por SSH + `kubectl apply -k`** | O Learner Lab não permite criar roles IAM, então OIDC não é possível |

Contexto acadêmico: o professor de DevOps avalia o uso de **code review e Pull
Request** com a `main` protegida, e exige **Kubernetes** na nuvem. Por isso a
proteção de branch é um entregável do trabalho, não um enfeite.

---

## Índice

1. [Arquitetura geral](#1-arquitetura-geral)
2. [Decisões estruturais](#2-decisões-estruturais)
3. [Responsabilidade de cada repositório](#3-responsabilidade-de-cada-repositório)
4. [Estratégia de branches](#4-estratégia-de-branches)
5. [Fluxo de Pull Requests](#5-fluxo-de-pull-requests)
6. [Proteção de branches](#6-proteção-de-branches)
7. [CODEOWNERS](#7-codeowners)
8. [Ambientes QA e PROD](#8-ambientes-qa-e-prod)
9. [Estratégia de GitHub Actions](#9-estratégia-de-github-actions)
10. [Workflows por repositório](#10-workflows-por-repositório)
11. [Workflows reutilizáveis](#11-workflows-reutilizáveis)
12. [Build, testes e qualidade](#12-build-testes-e-qualidade)
13. [Segurança e secrets](#13-segurança-e-secrets)
14. [Docker](#14-docker)
15. [Docker Compose](#15-docker-compose)
16. [GHCR](#16-ghcr)
17. [Deploy: Kubernetes e Vercel](#17-deploy-kubernetes-e-vercel)
18. [Estrutura do repositório](#18-estrutura-do-repositório)
19. [Fluxo completo](#19-fluxo-completo)
20. [Regras de merge](#20-regras-de-merge)
21. [QA](#21-qa)
22. [Produção](#22-produção)
23. [Alternativas que comparamos](#23-alternativas-que-comparamos)
24. [Histórico: Render → Kubernetes](#24-histórico-render--kubernetes)
25. [Recomendações finais](#25-recomendações-finais)

---

## 1. Arquitetura geral

O projeto tem três "camadas":

```text
┌──────────────────────────────────────────────────────────────────────┐
│ 1. CÓDIGO: um repositório por aplicação (todos públicos)             │
│    API · Mobile · Chatbot · Database · Website                       │
│    Cada um cuida do seu código, dos seus testes e do seu CI          │
└──────────────────────────────────────────────────────────────────────┘
                                │  chama
                                ▼
┌──────────────────────────────────────────────────────────────────────┐
│ 2. INFRAESTRUTURA COMPARTILHADA: este repositório (volta-devops)     │
│    Workflows reutilizáveis · Compose · Scripts · Manifestos · Docs   │
└──────────────────────────────────────────────────────────────────────┘
                                │  publica / aciona
                                ▼
┌──────────────────────────────────────────────────────────────────────┐
│ 3. EXECUÇÃO                                                          │
│    GHCR (imagens) · k3s na EC2 (API, Chatbot) · Vercel (Website)     │
│    Neon (PostgreSQL) · MongoDB Atlas                                 │
└──────────────────────────────────────────────────────────────────────┘
```

O caminho da imagem:

```text
Código → CI (build + teste) → imagem Docker → GHCR → repository_dispatch
                                                          │
                                       DevOps: kustomize edit set image
                                                          │
                                       SSH → kubectl apply -k → k3s

Website: Código → CI → Vercel (preview em develop, produção em main)
```

A ideia central é **"construir uma vez, implantar várias"**. A imagem que passou
nos testes é exatamente a mesma que sobe em QA e em produção. Nada é recompilado
no destino.

---

## 2. Decisões estruturais

### 2.1 Repositórios públicos

Deixar os repositórios públicos libera recursos que o plano gratuito do GitHub
só oferece nesse caso:

| Recurso | Para quê |
|---|---|
| Rulesets e proteção de branch | Bloquear merge com CI falhando (exigência da disciplina) |
| Environments | Secrets por ambiente e **aprovação manual antes de produção** |
| CODEOWNERS | Indicar automaticamente quem revisa cada área |
| Minutos de Actions ilimitados | Sem preocupação com cota |

**O custo:** nenhuma credencial pode ir para o Git. Apagar um segredo depois do
commit não resolve, pois ele continua no histórico. Ligue o **secret scanning**
e o **push protection** em todos os repositórios (é gratuito em repositório
público): eles bloqueiam o push antes de o segredo entrar no histórico.

### 2.2 Workflows reutilizáveis ficam em `.github/workflows/`

Um workflow reutilizável **precisa** estar em `.github/workflows/` do
repositório que o oferece. Uma pasta `workflows/` na raiz não funciona. Como este
repositório é público, qualquer repositório da organização pode chamá-lo.

### 2.3 Website na Vercel, sem Docker em produção

O Website é um conjunto de arquivos estáticos. Colocá-lo em container gastaria
memória do servidor (que já é pequeno) e exigiria manter um `nginx.conf`, sem
ganho. A Vercel já entrega deploy automático, CDN e **preview por Pull Request**.

O Dockerfile continua no repositório do Website, mas só para o Compose local.

### 2.4 O banco não fica no cluster

Rodar o Postgres dentro do k3s disputaria os 4 GB de memória da t3.medium com as
aplicações e daria trabalho extra de backup e restauração. Não agrega nada ao
que a disciplina avalia.

**Escolha: Neon.** O plano gratuito não expira e permite **branches de banco**.
Usamos um projeto com duas branches, `qa` e `prod`. Cada uma funciona como um
banco independente, mas nasce do mesmo ponto de partida. Isso facilita recriar o
QA a partir da produção para reproduzir um bug.

Ponto de atenção: o Neon gratuito **hiberna** depois de alguns minutos sem uso.
O primeiro acesso depois disso é mais lento (segundos, não minutos). Acorde-o
antes de uma demonstração, assim como a EC2.

**MongoDB (Chatbot):** Atlas M0 (gratuito, 512 MB), com dois bancos lógicos,
`volta_qa` e `volta_prod`.

**Redis e Neo4j:** hospedagem ainda a definir. A ideia é a mesma: serviço
gerenciado fora do servidor.

### 2.5 Imagens do GHCR públicas

O armazenamento é gratuito e o k3s baixa as imagens sem `imagePullSecret`. O
preço é que **tudo dentro da imagem é público**. Isso transforma várias
recomendações da seção 13 em obrigações.

---

## 3. Responsabilidade de cada repositório

| Repositório | Produz | CI | Deploy |
|---|---|---|---|
| **API** | `ghcr.io/app-volta/api` | Build e testes com Maven | k3s: QA automático, PROD com aprovação |
| **API Redis** | `ghcr.io/app-volta/api-redis` | Build e testes com Maven | k3s: QA automático, PROD com aprovação |
| **Mobile** | APK como artifact | Build, testes e lint com Gradle | Nenhum |
| **Chatbot** | `ghcr.io/app-volta/chatbot` | Ruff + pytest | k3s: QA automático, PROD com aprovação |
| **Website** | Arquivos estáticos | Lint, `tsc` e build | Vercel: preview (develop) e produção (main) |
| **Database** | Scripts SQL e `.drawdb` | Roda os scripts em um Postgres temporário | Nenhum |
| **DevOps** (este) | Workflows reutilizáveis, manifestos, Compose, docs | Validação dos YAML | Aplica os manifestos por SSH |
| **volta-landing-page** | Página do 1º ano | Nenhum | Fora desta arquitetura |

Detalhes que importam:

- **API.** Expõe `/actuator/health`, usado pelas verificações de saúde do
  Kubernetes e pelo smoke test depois do deploy. A porta vem da variável
  `SERVER_PORT`, o que mantém o container igual no Compose e no cluster.
- **Mobile.** Publica o APK de debug como artifact do workflow. Colegas e
  professor baixam o app pela aba Actions, sem compilar.
- **Database.** Não tem deploy nem migrations. O CI sobe um Postgres descartável
  e executa os scripts em ordem. Erro de sintaxe ou referência quebrada faz o CI
  falhar antes de a API tentar usar o schema.
- **Website.** O Vite grava as variáveis `VITE_*` no código **na hora do
  build**. Por isso a URL da API é configurada na Vercel, e **nenhum segredo
  pode ser `VITE_*`**.
- **DevOps.** Não tem código de aplicação. Regra prática: se um arquivo precisa
  mudar quando o código da aplicação muda, ele não é do DevOps.
- **volta-landing-page.** É do 1º ano, que não tem code review como requisito.
  Está fora do ruleset da organização.

---

## 4. Estratégia de branches

```text
main     ──●───────────────●──────────────●──────►  PRODUÇÃO
            ╲             ╱ ╲            ╱
develop  ────●───●───●───●───●───●───●──●─────────►  QA
              ╲ ╱     ╲ ╱         ╲ ╱
feat/SCRUM-1858 ●    ●            ●
```

Nome da branch de trabalho: `<tipo>/SCRUM-<número>`, validado automaticamente.

```regex
^(feat|fix|refactor|chore|test|docs)/SCRUM-[0-9]{1,4}$
```

Válidos: `feat/SCRUM-1858`, `fix/SCRUM-123`. Inválidos: `feat/SCRU-1858`,
`feat/scrum-1858`, `feat/SCRUM-1858-login`.

### Hotfix

Se a produção quebrar e `develop` tiver trabalho ainda não validado:

1. Crie `fix/SCRUM-123` **a partir de `main`**.
2. Abra PR para `main`, com os mesmos checks e aprovação.
3. Depois do merge, **abra um PR de `main` para `develop`**. Sem isso, o próximo
   `develop → main` traz o bug de volta.

Mais detalhes em [`05-padroes-git.md`](05-padroes-git.md).

---

## 5. Fluxo de Pull Requests

```text
 Ticket SCRUM-1858 no Jira
        │
        ├─► branch feat/SCRUM-1858 (a partir de develop)
        ├─► commits (Conventional Commits)
        ├─► PR para develop, ligado ao ticket
        │        │
        │        ├─ [auto] validate-pr: nome da branch, destino e título
        │        ├─ [auto] build-test: build, testes e lint
        │        ├─ [auto] revisor indicado pelo CODEOWNERS
        │        ├─ 1 aprovação obrigatória
        │        └─ conversas resolvidas
        │
        └─► squash merge em develop → dispara o deploy de QA
```

Três pontos importantes:

- **A chave do Jira na branch e no PR** liga ticket, branch, PR e commit.
- **PR de feature só pode ter `develop` como destino.**
- **Um PR, um ticket.** PRs que resolvem várias coisas são difíceis de revisar.

Checklist sugerido para o template de PR:

```markdown
- [ ] O CI passou nesta branch
- [ ] Testei localmente
- [ ] A issue vinculada está totalmente coberta
```

---

## 6. Proteção de branches

A proteção é configurada **uma vez, na organização**, e vale para todos os
repositórios.

### Pré-requisito: nomes de check iguais

Para um ruleset de organização funcionar, todos os repositórios precisam usar
os **mesmos nomes de job**:

```text
build-test
validate-pr
```

Ao chamar um workflow reutilizável, o nome que aparece é `job-chamador /
job-chamado`, por exemplo `validate-pr / validate-pr`. Rode o workflow uma vez,
copie o nome exato da interface e só então marque como obrigatório.

### Regras para `develop`

| Regra | Valor |
|---|---|
| Pull Request obrigatório | Sim |
| Aprovações necessárias | 1 |
| Descartar aprovações após novo push | Não |
| Checks obrigatórios | `validate-pr / validate-pr`, `build-test` |
| Exigir branch atualizada | Não |
| Resolver conversas | Sim |
| Bloquear force push e exclusão | Sim |

### Regras para `main`

| Regra | Valor |
|---|---|
| Pull Request obrigatório | Sim |
| Aprovações necessárias | 1 |
| Descartar aprovações após novo push | **Sim** |
| Exigir revisão de CODEOWNERS | **Sim** |
| Checks obrigatórios | `validate-pr / validate-pr`, `build-test` |
| Exigir branch atualizada | **Sim** |
| Resolver conversas | Sim |
| Bloquear force push e exclusão | Sim |

### Por que 1 aprovação, e não 2?

Em vários repositórios só uma ou duas pessoas conhecem o código. O GitHub não
deixa o autor aprovar o próprio PR. Exigir 2 aprovações com 2 pessoas
**trava todos os PRs**, e a saída seria desligar a regra na pressa, o que é pior
do que nunca ter ligado. Uma aprovação é uma regra que a equipe consegue cumprir.

Em `main`, o rigor extra vem de outros pontos: aprovação do CODEOWNER, descarte
de aprovações antigas e aprovação manual do Environment `prod`.

### Excluir o `volta-landing-page`

O 1º ano faz merge direto pelo terminal. Em **Organization settings →
Repository → Rulesets → (seu ruleset) → Targeting criteria**:

```text
Add a target → Include by pattern → *
Add a target → Exclude by pattern → volta-landing-*
```

O padrão `volta-landing-*` cobre o repositório atual e os futuros do 1º ano.

### Cuidado: filtros `paths` em check obrigatório

Se um workflow obrigatório for pulado por `paths-ignore`, o GitHub mostra o check
como "pendente" para sempre e o PR **nunca** pode ser mergeado. Não use filtro de
caminho em workflow que é check obrigatório.

---

## 7. CODEOWNERS

> **Estado atual:** este repositório ainda não tem o arquivo `.github/CODEOWNERS`.
> A seção descreve o que está planejado.

O CODEOWNERS indica automaticamente quem revisa cada parte do código. Junto com
"Exigir revisão de CODEOWNERS" em `main`, a aprovação da pessoa certa passa a ser
obrigatória.

Times sugeridos na organização:

```text
@app-volta/backend    @app-volta/mobile    @app-volta/frontend
@app-volta/data       @app-volta/ai        @app-volta/devops
```

Exemplo para a **API**:

```text
# Dono padrão de todo o repositório
*                       @app-volta/backend

# Pipeline e Docker são do time de DevOps
/.github/workflows/     @app-volta/devops
/Dockerfile             @app-volta/devops
/.dockerignore          @app-volta/devops

# Entidades JPA envolvem a modelagem de dados
/src/main/java/**/entity/    @app-volta/backend @app-volta/data
```

Três cuidados:

1. O time precisa ter **permissão de escrita** no repositório.
2. O time de DevOps precisa ter **pelo menos duas pessoas**. Com uma só, ninguém
   consegue aprovar o PR de quem altera um workflow.
3. Regras posteriores vencem as anteriores. Deixe a linha `*` no topo.

---

## 8. Ambientes QA e PROD

```text
develop ──► Environment "qa"   ──► namespace volta-qa   ──► Neon branch qa / Atlas volta_qa
                                   Vercel: preview

main    ──► Environment "prod" ──► namespace volta-prod ──► Neon branch prod / Atlas volta_prod
                                   Vercel: produção

Um único cluster k3s, dois namespaces. O isolamento é lógico: Secrets,
ConfigMaps, Services e quotas independentes por namespace.
```

Tabela completa e como ligar o QA: [`02-ambientes.md`](02-ambientes.md).

### Por que usar GitHub Environments

1. **Secrets por ambiente.** O mesmo nome pode ter valores diferentes em `qa` e
   `prod`. O workflow é um só.
2. **Aprovação manual antes de produção.** No Environment `prod`, marque
   *Required reviewers*. O deploy fica parado até alguém aprovar, mesmo com o
   merge feito. É o portão de produção.
3. **Restrição de branch.** `prod` só aceita deploy de `main`, e `qa` só de
   `develop`.

Bônus: a aba *Deployments* do repositório mostra o histórico de implantações, com
commit, autor e horário.

### Nomes

```text
namespace volta-qa      Services: api, api-redis, chatbot
namespace volta-prod    Services: api, api-redis, chatbot
```

O nome do Service é o mesmo nos dois namespaces. Quem diferencia é o namespace.
Assim os manifestos de `base/` ficam idênticos e a variação vai para os overlays.

### Orçamento da EC2

A t3.medium é cobrada por hora ligada. O disco de 30 GB (~US$ 2,40/mês) e o
Elastic IP (~US$ 3,60/mês) são cobrados mesmo com a máquina desligada.

| Cenário | Custo/mês | Cabe nos US$ 50? |
|---|---|---|
| Ligada ~2 h/dia | ~US$ 10 | Sim, com folga |
| Ligada ~8 h/dia | ~US$ 17 | Sim |
| Ligada 24h | ~US$ 37 | Gasta o crédito em ~5 semanas |

Regras:

- **A máquina liga sob demanda**, por workflow manual, e **desliga sozinha** após
  ~15 min sem tráfego (alarme do CloudWatch).
- **O QA fica com `replicas: 0`** por padrão. Liga quando alguém vai validar.
- **Em apresentações, ligue 10 minutos antes.** O mesmo vale para o Neon.

### Restrições do AWS Academy Learner Lab

| Restrição | Consequência |
|---|---|
| Não cria roles nem usuários IAM | **OIDC não é possível**, então o deploy é por SSH |
| Sem Identity Providers | Idem |
| EC2 limitada até `large` | A t3.medium é o melhor custo-benefício |
| Só `us-east-1` e `us-west-2` | Latência maior, aceita |
| Credenciais expiram em 4 h | Nenhuma credencial AWS vai para secret da aplicação. A EC2 usa o IMDS |
| A instância reinicia com IP novo | **Elastic IP é obrigatório** |
| `LabRole` e `LabInstanceProfile` já existem | São reaproveitados para S3 e CloudWatch |

---

## 9. Estratégia de GitHub Actions

### Regra de decisão: workflow local ou reutilizável?

> **O que muda junto, mora junto.**

| Pergunta | Se sim → |
|---|---|
| Depende do código do repositório (compilar, testar, lintar)? | Workflow local |
| É igual em 2+ repositórios, mudando só parâmetros? | Reutilizável no DevOps |
| Mexe com registro de imagens, credenciais ou plataforma de deploy? | Reutilizável no DevOps |
| Uma quebra aqui pararia todos os repositórios de uma vez? | Pense duas vezes |

| Componente | Onde fica | Por quê |
|---|---|---|
| Build e teste da API (Maven) | Local, na API | Muda quando o `pom.xml` muda |
| Build e teste do Mobile (Gradle) | Local, no Mobile | Idem |
| Build e teste do Website (npm) | Local, no Website | Idem |
| Build Docker + push no GHCR | **Reutilizável** | Igual para API e Chatbot |
| Deploy no k3s | **Reutilizável** | Igual para os três serviços |
| Validação de PR | **Reutilizável** | Regra da organização |
| Limpeza do GHCR | Workflow próprio do DevOps | Roda por agendamento |

A tentação errada é centralizar também o CI de cada linguagem. Parece evitar
duplicação, mas faz qualquer mudança no `pom.xml` exigir PR em outro repositório
e faz um erro derrubar todos de uma vez. Maven, Gradle, npm e pip são
ferramentas diferentes, não a mesma coisa com parâmetros.

### Convenções obrigatórias

```yaml
jobs:
  build-test:          # nome padronizado: é o que o ruleset exige

permissions:
  contents: read       # o mínimo; aumente só onde precisa

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true
```

Exceção: em jobs de **deploy**, use `cancel-in-progress: false`. Cancelar um
deploy no meio deixa o ambiente em estado incerto.

### Versionamento dos workflows reutilizáveis

Referencie por tag, nunca pela `main`:

```yaml
uses: app-volta/volta-devops/.github/workflows/reusable-docker-build-push.yaml@v1
```

Crie a tag `v1` e mova-a quando quiser propagar mudanças compatíveis. Sem isso,
um commit errado aqui quebra todos os outros repositórios na hora.

---

## 10. Workflows por repositório

### API e Chatbot

```text
ci.yml   gatilho: pull_request [develop, main] + push [develop, main]
         jobs: validate-pr (só em PR) | build-test

cd.yml   gatilho: push [develop, main] + workflow_dispatch
         jobs: build-test → docker (reutilizável) → deploy (reutilizável)
         ambiente pela branch: develop→qa, main→prod
```

O portão de produção é o *Required reviewer* do Environment `prod`, que segura o
job de deploy até alguém aprovar.

### Website

```text
ci.yml   jobs: validate-pr | build-test (lint, tsc, build)
```

Sem `cd.yml`: a integração nativa da Vercel faz o deploy.

### Mobile

```text
ci.yml   jobs: validate-pr | build-test → upload do APK
```

### Database

```text
ci.yml   jobs: validate-pr | build-test (scripts em Postgres temporário)
```

### DevOps (este repositório)

Arquivos que existem hoje em `.github/workflows/`:

```text
reusable-validate-pr.yaml         (workflow_call)
reusable-docker-build-push.yaml   (workflow_call)
reusable-k3s-deploy.yaml          (workflow_call)
dispatch-deploy.yaml              (repository_dispatch + workflow_dispatch)
ec2-power.yaml                    (workflow_dispatch)
ghcr-cleanup.yaml                 (agendado, mensal + manual)
```

> **Planejado, ainda não existe:** um `ci.yaml` com a validação dos YAML e do
> Compose, o `.github/CODEOWNERS` e o `.github/dependabot.yml`.

O repositório `.github` da organização fornece templates de PR e de issue para os
repositórios que não têm os seus. CODEOWNERS e Dependabot **não** são herdados e
precisam existir em cada repositório.

---

## 11. Workflows reutilizáveis

### 11.1 `reusable-validate-pr.yaml`

Não tem parâmetros. Lê o contexto do PR e verifica:

- o nome da branch (regex da seção 4);
- o destino do PR (feature → `develop`; `develop` → `main`; hotfix `fix/*` → `main`);
- o título no padrão Conventional Commits, que importa porque o squash merge usa o
  título do PR como mensagem do commit.

### 11.2 `reusable-docker-build-push.yaml`

```yaml
inputs:   image-name, environment, context, dockerfile, push,
          notify-devops, devops-repository
secrets:  devops-dispatch-token
outputs:  image, image-tag        # ghcr.io/app-volta/api, qa-a1b2c3d
```

O que faz: aceita só `qa` ou `prod` como ambiente, faz login no GHCR com o
`GITHUB_TOKEN`, gera a imagem para `linux/amd64` com cache de camadas, aplica as
tags da seção 16 e envia.

Se `notify-devops` estiver ligado, o último passo avisa este repositório
(`repository_dispatch`):

```json
{
  "event_type": "deploy",
  "client_payload": {
    "service": "api",
    "env": "qa",
    "image": "ghcr.io/app-volta/api",
    "tag": "qa-a1b2c3d",
    "commit": "<sha completo>",
    "source_repository": "app-volta/api"
  }
}
```

O `GITHUB_TOKEN` não consegue disparar workflow em outro repositório. É preciso um
PAT com escrita neste repositório, guardado no secret `devops-dispatch-token`. O
workflow falha de propósito se ele estiver ausente.

### 11.3 `reusable-k3s-deploy.yaml`

```yaml
inputs:   environment, service, image, image-tag, health-url, rollout-timeout, qa-smoke
secrets:  ssh-private-key
```

O host (`SSH_HOST`) vem da variável do repositório.

Passos do deploy:

1. Lê por SSH as imagens atuais dos três Deployments e guarda as dos serviços
   **não selecionados**.
2. Roda `kustomize edit set image` e troca o IP no overlay temporário do runner.
3. Envia os manifestos para a EC2 por `scp`.
4. Roda `kubectl apply -k kubernetes/overlays/<ambiente>`.
5. Confere se as imagens dos outros dois serviços continuam iguais.
6. Roda `kubectl rollout status` (só passa quando a verificação de saúde passa) e
   um smoke test no health check.
7. Escreve um resumo no `GITHUB_STEP_SUMMARY`.

O `kustomize` só é instalado (versão `5.4.3`) se o runner ainda não tiver o
binário.

O workflow **não** faz commit do overlay. As regras do repositório exigem PR para
mudar `main`. A tag e o resultado ficam no histórico do Actions.

O job declara `environment: ${{ inputs.environment }}`. É ele que fica parado
esperando aprovação em produção.

Se o Deployment estiver com `replicas: 0` (padrão em QA), o rollout e o smoke test
são pulados com um aviso. A imagem fica pronta para quando alguém ligar o
serviço.

### 11.3.1 `dispatch-deploy.yaml`

É a porta de entrada do deploy, com dois gatilhos:

- **`repository_dispatch`** (tipo `deploy`): automático, disparado pelos
  repositórios de aplicação depois de publicar a imagem;
- **`workflow_dispatch`**: manual, para reimplantar uma tag antiga sem rebuild. É
  o caminho de rollback pela interface.

Como o aviso vem de fora deste repositório, nada é usado sem validação:

- serviço e ambiente são conferidos contra uma lista fechada;
- a tag precisa seguir `<env>-<sha7>`;
- **o prefixo da tag precisa ser igual ao ambiente de destino** (isso impede
  implantar uma imagem de QA em produção);
- `qa-smoke` só vale para o chatbot em QA.

### 11.4 `ghcr-cleanup.yaml`

Roda uma vez por mês (e manualmente). Remove versões **sem tag** e mantém as 10
mais recentes de `api`, `api-redis` e `chatbot`.

Precisa de um PAT com escopo `delete:packages` no secret `GHCR_CLEANUP_TOKEN`,
porque o `GITHUB_TOKEN` não tem permissão sobre pacotes de outros repositórios.

---

## 12. Build, testes e qualidade

### API (Java 21, Spring Boot, Maven)

```text
checkout → setup-java (temurin 21, cache maven) → mvn -B verify → relatório surefire
```

O `mvn -B verify` faz dependências, compilação, testes e empacotamento em um
comando.

Qualidade proporcional: **Spotless ou Checkstyle** em modo de verificação.
Formatação consistente evita conflito bobo de merge. O SonarQube fica de fora:
exige servidor ou conta e não gera ações que o grupo vá tomar.

### Mobile (Android, Java, Gradle)

```text
checkout → setup-java 17 → setup-gradle (cache)
        → assembleDebug → testDebugUnitTest → lintDebug → upload do APK
```

O SDK do Android já vem no runner. Testes com emulador ficam fora do CI: são
lentos e instáveis.

### Chatbot (Python, FastAPI)

```text
checkout → setup-python 3.12 (cache pip) → pip install → ruff check → pytest
```

O Ruff substitui flake8, isort e black. **Não chame a LLM real no CI**: deixa a
esteira lenta, imprevisível e gasta cota paga.

### Website (TypeScript, React, Vite)

```text
checkout → setup-node 20 (cache npm) → npm ci → npm run lint
        → npx tsc --noEmit → npm run build
```

O `tsc --noEmit` é importante porque o Vite **não verifica tipos**. Sem ele, erros
de tipagem só aparecem na execução.

### Database (SQL)

```text
checkout → Postgres 16 → 01-schema.sql → 02-views.sql → 03-procedures.sql
         → 04-triggers.sql → 05-dataload.sql → consultas de sanidade
```

O banco nasce e morre dentro do runner. Exige uma convenção: **prefixo numérico
nos arquivos** para definir a ordem.

---

## 13. Segurança e secrets

> Onde cada segredo mora e como criá-lo: [`03-secrets.md`](03-secrets.md).

### Atenção 1: imagens públicas

Tudo dentro da imagem é público. Por isso:

- o `.dockerignore` **precisa** excluir `.env`, `*.pem`, `*.key` e
  `application-local.yml`;
- `application.yml` só tem placeholders (`${DB_PASSWORD}`), nunca valores;
- nada de chaves, senhas ou segredos em `ENV` ou `ARG` do Dockerfile;
- um JAR pode ser decompilado, então a imagem entrega o código a quem baixar.

Teste de cinco minutos, vale fazer uma vez:

```bash
docker run --rm -it ghcr.io/app-volta/api:latest sh
```

### Atenção 2: repositórios públicos

O histórico é público. Segredo apagado continua no histórico. Ligue **secret
scanning** e **push protection**.

### O que fica ligado (custo quase zero)

- **`permissions` mínimas** em todo workflow.
- **Dependabot** para maven, gradle, npm, pip, docker e github-actions.
- **Actions fixadas**: `@v4` para as oficiais, SHA completo para as de terceiros.
- **CodeQL**: é só um botão em repositório público. Cobre Java, Python e
  JavaScript.

Fora do escopo, de propósito: DAST, assinatura de imagem, SBOM e scan de
container. São boas práticas de empresa, mas não geram ação útil aqui.

### Onde cada informação fica

| Informação | Tipo | Onde fica |
|---|---|---|
| `SSH_PRIVATE_KEY` | Secret | GitHub (DevOps) |
| `SSH_HOST` (Elastic IP) | Variable | GitHub (DevOps) |
| `DEVOPS_DISPATCH_TOKEN` (PAT) | Secret | GitHub (repositórios de aplicação) |
| `GHCR_CLEANUP_TOKEN` (PAT) | Secret | GitHub (DevOps) |
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN` | Secrets temporários | GitHub (DevOps), só para ligar/desligar a EC2 |
| Senha do Postgres (Neon) | Secret | `Secret` do namespace no k3s |
| String de conexão do MongoDB | Secret | `Secret` do namespace no k3s |
| `JWT_KEY` | Secret | `Secret` do namespace (**diferente por ambiente**) |
| Chaves de API da LLM | Secret | `Secret` do namespace no k3s |
| Credenciais AWS da aplicação (S3) | Temporárias | IMDS da EC2, via `LabInstanceProfile` |
| `GITHUB_TOKEN` | Automático | Criado pelo Actions a cada execução |
| `VITE_*` do Website | Variable (**nunca secret**) | Painel da Vercel |
| Dockerfiles, Compose e manifestos | Versionado | Repositório |
| `.env.example` (chaves sem valores) | Versionado | Repositório |
| `.env` (com valores) | **Nunca versionado** | Máquina local |

### Onde o segredo da aplicação realmente fica

**Os segredos da aplicação não ficam no GitHub.** Senhas de banco, chaves de LLM e
JWT viram `Secret` do Kubernetes, criados à mão uma vez por namespace, porque
quem precisa deles é o container rodando, não a esteira. O GitHub guarda só o que
a *esteira* precisa: a chave SSH e os tokens.

As credenciais AWS da aplicação nunca vão para o GitHub. A EC2 as recebe sozinha
pelo IMDS (`LabInstanceProfile`) e elas se renovam.

Usar `JWT_KEY` diferente em QA e produção garante que um token emitido em QA não
valha em produção.

---

## 14. Docker

### Princípios

- **Multi-stage sempre**: o compilador não vai para produção.
- **`linux/amd64` obrigatório**, a arquitetura da EC2. Quem usa Mac com Apple
  Silicon gera `arm64` por padrão, e o pod entra em `CrashLoopBackOff` com
  `exec format error`.
- **Usuário não-root** no estágio final.
- **Porta por variável de ambiente**: definida no ConfigMap do overlay e igual ao
  `containerPort` do Deployment.
- **`.dockerignore` sempre**. Com imagem pública, ele também é controle de
  segurança.

### API

Build com `maven:3.9-eclipse-temurin-21` e execução com
`eclipse-temurin:21-jre-alpine`. Copiar o `pom.xml` antes do `src` permite
reaproveitar a camada de dependências enquanto o `pom.xml` não mudar. Resultado:
~200 MB, contra ~600 MB com o JDK completo.

### Chatbot

`python:3.12-slim`, `pip install --no-cache-dir`, usuário não-root e
`uvicorn --host 0.0.0.0 --port ${PORT:-8000}`.

### Website

Dockerfile só para o Compose local (build com Node → nginx). Em produção quem
publica é a Vercel.

### Rastreabilidade

```dockerfile
LABEL org.opencontainers.image.source="https://github.com/app-volta/API"
LABEL org.opencontainers.image.revision="${GIT_SHA}"
```

O label `source` liga o pacote do GHCR ao repositório.

---

## 15. Docker Compose

Arquivo: `docker-compose/docker-compose.yaml`. Guia de uso:
[`docker-compose/README.md`](../docker-compose/README.md).

| Serviço | No Compose? | Motivo |
|---|---|---|
| `postgres` | Sim | Banco local |
| `mongo` | Sim | Necessário ao Chatbot |
| `api` | Sim | Quem trabalha no Mobile precisa da API sem instalar Java |
| `chatbot` | Sim, com `ENVIRONMENT: qa` | Idem |
| Website | Não | `npm run dev` é mais rápido e tem hot reload |
| Mobile | Não | Android precisa de SDK e emulador |
| Proxy reverso | Não | Traefik (no cluster) e Vercel já cuidam disso |

Os repositórios devem ficar **lado a lado** (`volta-api`, `volta-chatbot`,
`volta-devops`), porque o Compose usa caminhos relativos como
`../../volta-api`.

> **Planejado, ainda não existe:** *profiles* (`apps`, `tools`), ferramentas de
> administração (pgAdmin, mongo-express) e um segundo arquivo
> `docker-compose.ghcr.yml` que usaria as imagens já publicadas (funcionaria sem
> login, pois as imagens são públicas).

A ideia para o futuro é montar no Postgres os mesmos scripts do repositório
Database em `/docker-entrypoint-initdb.d`, para que a fonte do schema seja uma só.

---

## 16. GHCR

### Nomes

```text
ghcr.io/app-volta/api
ghcr.io/app-volta/api-redis
ghcr.io/app-volta/chatbot
```

Sem `website` (vai para a Vercel). Sem sufixo de ambiente no nome: **a mesma
imagem serve QA e PROD**. O ambiente é *tag* e *serviço*, não uma imagem diferente.

### Tags

| Tag | Muda? | Para quê |
|---|---|---|
| `qa-a1b2c3d` | **Nunca** | O que está em QA. Todo deploy de QA fixa uma tag assim |
| `prod-a1b2c3d` | **Nunca** | O que está em produção |
| `qa` | Sim | Aponta para o mais recente de QA |
| `prod` | Sim | Aponta para o mais recente de produção |

O prefixo do ambiente na tag permite saber, só olhando o `image:` de um
Deployment, de qual esteira veio a imagem. O deploy **sempre** usa a tag fixa. As
tags móveis são só conveniência. É isso que torna o rollback simples e o
histórico auditável.

Não usamos versionamento semântico, porque não há processo de release. Uma versão
que ninguém incrementa com critério é pior do que nenhuma.

### Quando construir e publicar

| Evento | Build? | Push? |
|---|---|---|
| PR para `develop` ou `main` | Não | Não |
| Merge em `develop` | Sim | `qa-<sha>` + `qa` |
| Merge em `main` | Sim | `prod-<sha>` + `prod` |

Não construir imagem no PR deixa o retorno rápido: o CI já compila e testa.

### Permissões

Publicar exige só:

```yaml
permissions:
  contents: read
  packages: write
```

Baixar não exige nada, pois as imagens são públicas.

### Dois passos manuais, uma vez só

1. Em *Organization settings → Packages*, permita pacotes **públicos**.
2. O primeiro push cria o pacote como **privado**. Em *Package settings → Change
   visibility → Public*, torne-o público (uma vez por imagem).

Se esquecer o passo 2, o pod fica em `ImagePullBackOff`.

### Limpeza

A limpeza mensal apaga versões sem tag e mantém as 10 mais recentes (seção 11.4).

Cuidado: apagar uma tag em uso **derruba o serviço no próximo reinício**, porque
o nó volta ao registro para baixar a imagem. Nunca apague `qa` ou `prod`, e
mantenha as tags `<env>-<sha>` recentes, que são o alvo do rollback.

---

## 17. Deploy: Kubernetes e Vercel

### 17.1 API e Chatbot: k3s na EC2

**Por que k3s e não EKS?** O EKS cobra ~US$ 73/mês só pelo plano de controle,
146% do crédito do Learner Lab, antes de rodar um pod. O k3s é Kubernetes
certificado pela CNCF: mesma API, mesmo `kubectl`, mesmos manifestos. O que se
perde é alta disponibilidade, que não é requisito aqui.

| | EKS | **k3s em EC2** (escolhido) | Render (anterior) |
|---|---|---|---|
| Atende "usar Kubernetes" | Sim | **Sim** | Não |
| Custo do plano de controle | ~US$ 73/mês | **US$ 0** | n/a |
| Cabe no Learner Lab | Não | **Sim** | n/a |
| Alta disponibilidade | Sim | Não (nó único) | Parcial |

**Estrutura:**

```text
EC2 t3.medium (Amazon Linux 2023) + Elastic IP
└── k3s (um nó, com Traefik embutido)
    ├── namespace volta-qa     → api, api-redis, chatbot  (replicas: 0 por padrão)
    └── namespace volta-prod   → api, api-redis, chatbot
```

Sem load balancer e sem NAT Gateway, os dois maiores gastos de crédito numa conta
AWS pequena. O Traefik do k3s faz o papel de entrada.

**Endereços.** O `sslip.io` resolve qualquer IP embutido no nome, então não
precisamos comprar domínio e conseguimos HTTPS com cert-manager:

```text
api.qa.<EIP>.sslip.io      → api        (volta-qa,   porta 8080)
api.<EIP>.sslip.io         → api        (volta-prod, porta 8080)
ranking.qa.<EIP>.sslip.io  → api-redis  (volta-qa,   porta 8081)
ranking.<EIP>.sslip.io     → api-redis  (volta-prod, porta 8081)
chat.qa.<EIP>.sslip.io     → chatbot    (volta-qa,   porta 8000)
chat.<EIP>.sslip.io        → chatbot    (volta-prod, porta 8000)
```

**Kustomize.** `base/` é o que é igual nos dois ambientes; cada overlay descreve
só a diferença.

```text
kubernetes/
├── namespace.yaml
├── base/
│   ├── api/{deployment,service,kustomization}.yaml
│   ├── api-redis/{deployment,service,kustomization}.yaml
│   ├── chatbot/{deployment,service,kustomization}.yaml
│   ├── ingress.yaml
│   └── kustomization.yaml
└── overlays/
    ├── qa/{kustomization,configmap,https-patch,replicas-patch,cluster-issuer}.yaml
    └── prod/{kustomization,configmap,resources-patch}.yaml
```

O deploy roda `kustomize edit set image` num overlay temporário do runner e aplica
na EC2. A tag e o resultado ficam no histórico do Actions. Os valores de cada
deploy não são gravados em `main`.

**Autenticação do deploy: SSH.** O Learner Lab não permite criar roles IAM, o que
elimina OIDC e SSM. Sobra a chave SSH: a pública fica no `authorized_keys` da
instância e a privada no secret `SSH_PRIVATE_KEY`.

**Verificações de saúde.** A API usa `/actuator/health/readiness` e
`/actuator/health/liveness`; o Chatbot usa `/health`. Sem essas verificações, o
`kubectl rollout status` diria "sucesso" antes de a aplicação estar de pé e o
deploy ficaria verde com o serviço quebrado.

**Secrets no cluster.** Criados à mão com `kubectl create secret`, uma vez por
namespace. Não usamos Sealed Secrets: a complexidade não compensa aqui, e exigiria
gerenciar uma chave que ninguém manteria.

**Fotos do mobile.** Não passam pelo cluster. A API gera uma URL assinada do S3
(expira em 15 min, com tipo de arquivo restrito), o mobile envia direto para o
bucket e a API só guarda a referência no banco. Com 512 MB de memória, enviar a
foto pelo Spring Boot não aguentaria dois usuários ao mesmo tempo.

### 17.2 Website: Vercel

| Item | Valor |
|---|---|
| Production Branch | `main` |
| Preview | Automático em `develop` e em cada PR |
| Framework | Vite |
| Build Command | `npm run build` |
| Output Directory | `dist` |
| Env (Production) | URL da API de PROD |
| Env (Preview) | URL da API de QA |

`develop` gera um preview com URL estável (QA) e `main` publica em produção. Como
o ruleset bloqueia merge com CI falhando, o deploy automático é seguro.

Rollback: a Vercel guarda todos os deployments; basta promover um anterior.

O plano Hobby é para uso não comercial. Um projeto acadêmico se enquadra.
Configuração completa: [`07-vercel-website.md`](07-vercel-website.md).

---

## 18. Estrutura do repositório

```text
volta-devops/
├── .github/
│   └── workflows/
│       ├── reusable-validate-pr.yaml
│       ├── reusable-docker-build-push.yaml
│       ├── reusable-k3s-deploy.yaml
│       ├── dispatch-deploy.yaml
│       ├── ec2-power.yaml
│       └── ghcr-cleanup.yaml
│
├── docker-compose/
│   ├── docker-compose.yaml
│   ├── .env.example
│   └── README.md
│
├── kubernetes/
│   ├── namespace.yaml
│   ├── base/        (api, api-redis, chatbot, ingress)
│   └── overlays/    (qa, prod)
│
├── scripts/
│   ├── lib-aws.sh               # funções compartilhadas
│   ├── provision-ec2-k3s.sh     # cria o cluster (roda local)
│   ├── cloud-init-k3s.sh        # roda no 1º boot: instala o k3s
│   ├── update-aws-session.sh    # renova credenciais do Learner Lab
│   └── rollback.sh              # rollback de emergência
│
├── docs/
│   ├── 01-arquitetura-cicd.md   ← este documento
│   ├── 02-ambientes.md
│   ├── 03-secrets.md
│   ├── 04-runbook-deploy.md
│   ├── 05-padroes-git.md
│   ├── 06-cluster-k3s.md
│   └── 07-vercel-website.md
│
├── LICENSE
└── README.md
```

---

## 19. Fluxo completo

```text
╔══════════════════════════════════════════════════════════════════════════╗
║ DESENVOLVIMENTO                                                          ║
╚══════════════════════════════════════════════════════════════════════════╝
  Ticket SCRUM-1858  ──►  git switch -c feat/SCRUM-1858  (a partir de develop)
                            │  commits + push
                            ▼
                  ┌──────────────────────┐
                  │  Pull Request        │
                  │  destino: develop    │
                  └──────────┬───────────┘
╔════════════════════════════▼═════════════════════════════════════════════╗
║ CI: em todo pull_request                                                 ║
╚══════════════════════════════════════════════════════════════════════════╝
        validate-pr                    build-test
   ┌────────────────────┐      ┌────────────────────────────┐
   │ nome da branch     │      │ checkout                   │
   │ destino permitido  │  ||  │ setup + cache              │
   │ título do PR       │      │ build / testes / lint      │
   └────────┬───────────┘      └────────────┬───────────────┘
            └───────────────┬───────────────┘
                            ▼
              ┌──────────────────────────────────────────┐
              │ RULESET: merge bloqueado se falhar       │
              │ + 1 aprovação + conversas resolvidas     │
              └──────────────┬───────────────────────────┘
                             ▼  SQUASH MERGE
╔══════════════════════════════════════════════════════════════════════════╗
║ DEPLOY DE QA: push em develop                                            ║
╚══════════════════════════════════════════════════════════════════════════╝
   build-test ──► docker-build-push ──► repository_dispatch ──► DevOps
                  ┌──────────────────────┐   ┌──────────────────────────┐
                  │ login no GHCR        │   │ kustomize edit set image │
                  │ build amd64          │   │ preserva outras imagens  │
                  │ tags: qa-a1b2c3d, qa │   │ ssh: kubectl apply -k qa │
                  │ push                 │   │ rollout status + /health │
                  └──────────────────────┘   └────────────┬─────────────┘
                                                          ▼
                                          k3s: namespace volta-qa
                                          Neon branch qa / Atlas volta_qa

                             │  validação manual em QA (checklist)
                             ▼
              ┌──────────────────────────────────────┐
              │ PR: develop ──► main                 │
              │ merge commit, NUNCA squash           │
              │ + CODEOWNER + branch atualizada      │
              └──────────────────┬───────────────────┘
                                 ▼
╔══════════════════════════════════════════════════════════════════════════╗
║ DEPLOY DE PRODUÇÃO: push em main                                         ║
╚══════════════════════════════════════════════════════════════════════════╝
   build-test ──► docker-build-push ──► ⏸ APROVAÇÃO MANUAL
                  (tags: prod-a1b2c3d,   (Environment prod:
                         prod)            required reviewers)
                                                    │
                                                    ▼
                                    ssh: kubectl apply -k prod + smoke test
                                                    │
                                                    ▼
                                        k3s: namespace volta-prod
                                        Neon branch prod / Atlas volta_prod

╔══════════════════════════════════════════════════════════════════════════╗
║ WEBSITE                                                                  ║
╚══════════════════════════════════════════════════════════════════════════╝
   PR → CI (bloqueante) → preview da Vercel no PR
                        → merge em develop → preview de QA
                        → merge em main    → produção

╔══════════════════════════════════════════════════════════════════════════╗
║ FORA DA ESTEIRA DE DEPLOY                                                ║
╚══════════════════════════════════════════════════════════════════════════╝
  Mobile             → CI + APK como artifact. Sem deploy.
  Database           → CI em Postgres temporário. Sem deploy.
  DevOps             → limpeza mensal do GHCR + recebe o aviso de deploy.
  EC2/k3s            → liga manualmente; desliga sozinha após ~15 min ociosa.
  volta-landing-page → fora do ruleset e desta arquitetura.
```

---

## 20. Regras de merge

| De → Para | Tipo de merge | Aprovação | Checks |
|---|---|---|---|
| `feat\|fix\|...` → `develop` | **Squash** | 1 | `validate-pr`, `build-test` |
| `develop` → `main` | **Merge commit** | 1 + CODEOWNER | Idem |
| `fix/*` (de `main`) → `main` | Squash | 1 + CODEOWNER | Idem |
| Push direto | **Bloqueado** | n/a | n/a |

### Por que squash de feature para develop?

O histórico de `develop` fica com um commit por tarefa, fácil de ler e de
reverter. Commits como "wip" ou "corrige typo" somem, e isso é bom. Como a
distribuição de commits entre colaboradores é critério de avaliação, um commit
limpo por tarefa conta mais do que quarenta commits barulhentos.

### Por que NUNCA squash de develop para main?

O squash cria um commit **novo** em `main`, sem ligação com os commits de
`develop`. O Git passa a achar que as branches divergiram e o próximo PR
`develop → main` traz de volta tudo que já foi mergeado, com conflitos. Depois de
dois ou três ciclos, fica ingovernável.

Em *Settings → General → Pull Requests*:

- [x] Allow squash merging (padrão: título do PR)
- [x] Allow merge commits
- [ ] Allow rebase merging
- [x] Automatically delete head branches

---

## 21. QA

O QA é **onde se decide se algo pode ir para produção**. Precisa de três coisas:

1. **Dados próprios**: branch `qa` no Neon e `volta_qa` no Atlas.
2. **Configuração igual à de produção**: mesma imagem, mesmas variáveis com
   valores diferentes, mesmo health check.
3. **Ser descartável**: dá para apagar e recriar o banco de QA com os scripts do
   repositório Database, sem pedir autorização.

### Automático

```text
merge em develop → build + testes → imagem (qa-<sha> + qa)
                 → deploy em volta-qa → smoke test em /health
```

### Validação manual antes do PR para `main`

- fluxo principal de ponta a ponta (Mobile de debug apontando para a API de QA);
- funcionalidade nova, conforme a tarefa;
- nada que funcionava deixou de funcionar;
- Chatbot respondendo com o banco de QA;
- Website: preview da Vercel da branch `develop`.

Coloque esse checklist no template do PR `develop → main`. Checklist que vive no
PR é lido; checklist em documento separado não é.

### Mobile e QA

Gere a variante de debug apontando para a API de QA (com `buildConfigField` ou
product flavors) e a de release para PROD. O APK de debug publicado como artifact
é o que o grupo instala para validar.

---

## 22. Produção

### Os 7 portões

```text
1. CI passou no PR para develop          (automático)
2. Validado em QA                        (checklist)
3. PR develop → main aprovado por CODEOWNER   ← ação humana
4. CI rodou de novo no merge             (automático)
5. Imagem publicada (prod-<sha> + prod)  (automático)
6. ⏸ Aprovação manual no Environment prod     ← ação humana
7. Deploy + smoke test                   (automático)
```

Sete portões, dois com ação humana (3 e 6). O resto é automático.

### Rollback

Passo a passo: [`04-runbook-deploy.md`](04-runbook-deploy.md#voltar-uma-versão-rollback).
Em resumo, em ordem de rapidez:

1. **`scripts/rollback.sh` (segundos).** Volta o Deployment para a revisão
   anterior ou para uma tag exata, direto no cluster. Depois que o serviço se
   recuperar, registre a tag boa numa execução do workflow Deploy.
2. **Workflow Deploy com uma tag anterior (1–2 min).** É para isso que as tags
   imutáveis existem: sem rebuild, sem PR, sem esperar o CI. O workflow preserva
   as imagens dos outros serviços.
3. **`git revert` de uma mudança de manifesto**, seguido de PR e esteira normal.
   Serve quando uma mudança versionada causou o problema. Para uma regressão só da
   aplicação, reimplante a tag anterior.

Website: promova um deployment anterior no painel da Vercel.

**Regra:** a limpeza do GHCR nunca pode apagar as tags `<env>-<sha>` recentes.

---

## 23. Alternativas que comparamos

### 23.1 Multi-repo ou monorepo

| | **Multi-repo** (escolhido) | Monorepo |
|---|---|---|
| CI independente | Natural | Exige filtros de caminho |
| Visibilidade da contribuição individual | **Alta** | Diluída |
| Mudança que cruza componentes | Vários PRs | Um PR |
| Configuração repetida | Alta (reduzida por workflows reutilizáveis) | Baixa |

Combina com a divisão por disciplina e deixa clara a contribuição de cada
pessoa, que é critério de avaliação.

### 23.2 Visibilidade dos repositórios

| | **Públicos** (escolhido) | Privados no plano gratuito |
|---|---|---|
| Proteção de branch / ruleset | ✅ | ❌ |
| Environments com aprovação | ✅ | ❌ |
| CODEOWNERS | ✅ | ❌ |
| Minutos de Actions | Ilimitados | 2.000/mês na organização |
| Código fechado | ❌ | ✅ |

A decisão partiu do professor de DevOps, que avalia code review e PR com `main`
protegida. Em repositório privado no plano gratuito, esses recursos não existem.

### 23.3 Onde ficam os workflows

| Abordagem | Vantagens | Desvantagens | Uso aqui |
|---|---|---|---|
| Duplicar em cada repositório | Autonomia total | Corrigir um bug = 5 PRs | CI de cada linguagem |
| **Reutilizável no DevOps** | Uma fonte, com versão | Repositórios ficam acoplados | Docker e deploy |
| Composite action | Reuso fino de passos | Sem `permissions`/`environment` próprios | Não por ora |
| Starter workflow | Sem acoplamento | As cópias divergem | Só para começar |

### 23.4 Registro de imagens

| | **GHCR** (escolhido) | Docker Hub |
|---|---|---|
| Login no CI | `GITHUB_TOKEN`, sem configurar | Secret com credencial |
| Limite de downloads | Sem limite relevante | Limitado no gratuito |
| Integração com o repositório | Nativa | Externa |

### 23.5 Hospedagem do Website

| | **Vercel** (escolhido) | Render Static Site | Container nginx |
|---|---|---|---|
| Custo | Grátis (Hobby) | Grátis | Gasta memória do nó |
| Preview por PR | ✅ nativo | Parcial | Não |
| Partida a frio | Não tem | Não tem | ~1 min |
| O que manter | Nada | Nada | Dockerfile + nginx.conf |

### 23.6 Banco Postgres

| | Render Free | **Neon Free** (escolhido) | Aiven Free |
|---|---|---|---|
| Expira | **30 dias** | Não | Não |
| Instâncias gratuitas | 1 por workspace | Vários projetos | 1 por conta |
| Branches de banco | Não | **Sim** | Não |
| Hiberna por inatividade | Não | Sim | Sim |
| Serve QA + PROD sem gambiarra | Não | **Sim**, via branches | Exigiria 2 contas ou 2 bancos lógicos |

O branching do Neon dá QA e PROD isolados no mesmo projeto gratuito, sem
administrar duas contas.

### 23.7 Como disparar o deploy

| | **repository_dispatch + SSH** (escolhido) | OIDC + SSM | GitOps (Argo CD) |
|---|---|---|---|
| Configuração | PAT + chave SSH | Role IAM + agente | Controlador no cluster |
| Fixa tag imutável | ✅ via kustomize | ✅ | ✅ |
| Funciona no Learner Lab | **Sim** | **Não** (sem IAM) | Sim, mas pesa no nó |
| Estado versionado no Git | Não (histórico do Actions) | Não | Sim |

### 23.8 Modelo de branches

| | Git Flow completo | **Simplificado** (escolhido) | Trunk-based |
|---|---|---|---|
| Branches permanentes | main, develop, release | main, develop | main |
| Ambientes | 3+ | 2 | 1–2 |
| Serve a equipe pequena | Não | Sim | Sim, com feature flags |

Trunk-based exigiria feature flags e uma disciplina de testes que o projeto ainda
não tem. Duas branches mapeiam direto nos dois ambientes, o que facilita explicar
a arquitetura numa arguição.

---

## 24. Histórico: Render → Kubernetes

A versão 3 deste documento tratava Kubernetes como evolução futura, porque não
havia necessidade de escala nem de alta disponibilidade. Isso continua verdade. O
que mudou foi que **Kubernetes virou exigência explícita da disciplina**, junto
com usar a nuvem. Deixou de ser escolha técnica e virou entregável avaliado.

O que **não** precisou mudar (prova de que a base era sólida):

- os Dockerfiles;
- as imagens no GHCR e as tags imutáveis;
- os workflows de CI e a validação de PR;
- a separação QA/PROD, os Environments e os secrets;
- o ruleset, o CODEOWNERS e o fluxo de branches.

Mudou só o **último passo** da esteira:

```text
antes:  build → GHCR → deploy hook (Render)
agora:  build → GHCR → repository_dispatch → kustomize → SSH → kubectl apply
```

| Item | Antes (v3) | Agora (v4 em diante) |
|---|---|---|
| Onde roda | Render | k3s em EC2 t3.medium |
| Gatilho do deploy | Deploy hook com `imgURL` | `repository_dispatch` + SSH |
| Tag imutável | `sha-a1b2c3d` | `<env>-a1b2c3d` |
| Isolamento de ambiente | 2 serviços por app | 2 namespaces |
| `reusable-render-deploy.yml` | Existia | **Removido** |
| Manifestos | n/a | `kubernetes/` com Kustomize |

### O que ficou de fora, e por quê

- **Argo CD / Flux.** O controlador gastaria memória do nó único, que é o recurso
  mais escasso. O histórico do Actions já registra tags e resultados.
- **Sealed Secrets.** Usamos `kubectl create secret` à mão, uma vez por namespace.
- **Cluster com vários nós.** Alta disponibilidade custaria ~4x o orçamento sem
  ajudar no que é avaliado. Nó único é um ponto único de falha: decisão
  consciente.
- **EKS.** ~US$ 73/mês só de plano de controle, 146% do crédito.

---

## 25. Recomendações finais

**Ordem de implantação.** (1) DevOps com os workflows reutilizáveis; (2) CI da
API; (3) build e push da API + Dockerfile; (4) Compose; (5) EC2 + k3s + Elastic
IP; (6) manifestos e deploy da API; (7) Chatbot; (8) Website + Vercel; (9) Mobile
e Database. A API é o piloto: os erros aparecem uma vez, não cinco.

**Ligue o ruleset só depois de o CI rodar verde uma vez.** Ligar antes bloqueia
todo mundo, e a primeira reação é pedir para desligar. Copie o nome exato do
check pela interface.

**Exclua o `volta-landing-*` do ruleset** antes que o 1º ano trave num merge que
eles não precisam fazer por PR.

**Padronize os nomes dos jobs.** `build-test` e `validate-pr` em todos os
repositórios permitem um único ruleset de organização.

**Crie a tag `v1` neste repositório** antes de usar os workflows reutilizáveis
em outros, senão o `@v1` não resolve.

**Use `concurrency` em tudo.** `cancel-in-progress: true` no CI e `false` no
deploy.

**Health check faz parte da infraestrutura.** Sem `/actuator/health` e `/health`
não há verificação de saúde, nem smoke test, e o `kubectl rollout status`
declara sucesso antes de a aplicação estar de pé.

**Revise o que entra na imagem pública.** Rode `docker run --rm -it
ghcr.io/app-volta/api:prod sh` uma vez e veja o que há lá dentro.

**Mantenha um `.env.example` completo em cada repositório.** É a documentação
que as pessoas realmente leem.

**Crie o Elastic IP na primeira sessão do lab.** Sem ele, cada reinício troca o
IP público, o que quebra o SSH do deploy e todos os endereços `sslip.io` de uma
vez.

**Confira o AWS Budget.** Alertas em US$ 10, US$ 25 e US$ 40. O maior risco é
uma instância esquecida ligada, e o desligamento automático existe para isso.

**Documente a decisão, não só a configuração.** Numa arguição, explicar por que o
deploy fixa a tag `<env>-<sha>` em vez da tag móvel, ou por que k3s em vez de EKS,
vale mais do que recitar o YAML.

---

*Documento mantido pelo time de DevOps · Projeto Volta*
