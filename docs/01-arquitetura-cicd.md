# Arquitetura de CI/CD — Projeto Volta

> Repositório: `app-volta/DevOps` · Caminho: `docs/01-arquitetura-cicd.md`
> Versão 3 — revisada após a abertura dos repositórios e a criação do ruleset de organização.

---

## Decisões fechadas

| Decisão | Consequência |
|---|---|
| **Todos os repositórios públicos** | Proteção de branch, rulesets, Environments e CODEOWNERS disponíveis; minutos de Actions ilimitados |
| **Ruleset no nível da organização**, mínimo 1 aprovação | Uma configuração vale para todos os repositórios, com exclusão do `volta-landing-page` |
| **Imagens no GHCR públicas** | Storage gratuito; Render e Compose sem credencial |
| **API e Chatbot no Render**, **Website na Vercel** | Sem consumo de horas do Render para o front |
| **Postgres no Neon**, MongoDB no Atlas | Fora do Render, que expira bancos gratuitos em 30 dias |

Requisito acadêmico registrado: o professor de DevOps avalia o uso de **code
review e Pull Request** com proteção da `main`. Isso eleva a proteção de branch
de "boa prática" a **entregável avaliado** — ela é parte do trabalho, não
enfeite da esteira.

---

## Índice

1. [Arquitetura geral](#1-arquitetura-geral)
2. [Decisões estruturais](#2-decisões-estruturais)
3. [Responsabilidade de cada repositório](#3-responsabilidade-de-cada-repositório)
4. [Estratégia de branches](#4-estratégia-de-branches)
5. [Fluxo de Pull Requests](#5-fluxo-de-pull-requests)
6. [Proteção de branches e ruleset](#6-proteção-de-branches-e-ruleset)
7. [CODEOWNERS](#7-codeowners)
8. [Ambientes QA e PROD](#8-ambientes-qa-e-prod)
9. [Estratégia de GitHub Actions](#9-estratégia-de-github-actions)
10. [Workflows por repositório](#10-workflows-por-repositório)
11. [Workflows reutilizáveis no DevOps](#11-workflows-reutilizáveis-no-devops)
12. [Pipelines de build, testes e qualidade](#12-pipelines-de-build-testes-e-qualidade)
13. [Segurança e secrets](#13-segurança-e-secrets)
14. [Estratégia de Docker](#14-estratégia-de-docker)
15. [Estratégia de Docker Compose](#15-estratégia-de-docker-compose)
16. [Estratégia de GHCR](#16-estratégia-de-ghcr)
17. [Deploy: Render e Vercel](#17-deploy-render-e-vercel)
18. [Estrutura de diretórios do DevOps](#18-estrutura-de-diretórios-do-devops)
19. [Fluxo completo em diagrama](#19-fluxo-completo-em-diagrama)
20. [Regras de merge](#20-regras-de-merge)
21. [Estratégia de QA](#21-estratégia-de-qa)
22. [Estratégia de produção](#22-estratégia-de-produção)
23. [Comparação das alternativas arquiteturais](#23-comparação-das-alternativas-arquiteturais)
24. [Evolução futura para Kubernetes](#24-evolução-futura-para-kubernetes)
25. [Recomendações finais](#25-recomendações-finais)

---

## 1. Arquitetura geral

```text
┌──────────────────────────────────────────────────────────────────────┐
│ PLANO 1 — CÓDIGO (um repositório por aplicação, todos públicos)      │
│  API · Mobile · Chatbot · Database · Website                         │
│  Cada repo é dono do seu código, dos seus testes e do seu CI         │
└──────────────────────────────────────────────────────────────────────┘
                                │  workflow_call
                                ▼
┌──────────────────────────────────────────────────────────────────────┐
│ PLANO 2 — INFRAESTRUTURA COMPARTILHADA (repositório DevOps)          │
│  Reusable workflows · Compose · Scripts · render.yaml · Docs         │
└──────────────────────────────────────────────────────────────────────┘
                                │  publica / aciona
                                ▼
┌──────────────────────────────────────────────────────────────────────┐
│ PLANO 3 — EXECUÇÃO                                                   │
│  GHCR (imagens públicas) · Render (API, Chatbot) · Vercel (Website)  │
│  Neon (PostgreSQL) · MongoDB Atlas                                   │
└──────────────────────────────────────────────────────────────────────┘
```

Fluxo do artefato:

```text
Código → CI (build + teste) → Imagem Docker → GHCR → Render
                                                 │
                                        deploy hook fixando a tag exata

Website: Código → CI → Vercel (preview em develop, produção em main)
```

O princípio que governa tudo é **build once, deploy many**: a imagem que passou
nos testes é exatamente a mesma que sobe em QA e em PROD. Nada é reconstruído
no destino.

---

## 2. Decisões estruturais

### 2.1 Repositórios públicos

A abertura dos repositórios destrava quatro recursos que o plano Free restringe
a repositórios públicos:

| Recurso | Efeito na arquitetura |
|---|---|
| Rulesets e proteção de branch | Merge bloqueado com CI falhando — requisito avaliado da disciplina |
| Environments | Secrets por ambiente e **aprovação manual antes de produção** |
| CODEOWNERS | Atribuição automática de revisor por área |
| Minutos de Actions ilimitados | Sem orçamento de minutos a administrar |

Contrapartida: **nenhuma credencial pode ir para o Git**, e um secret commitado
e removido depois continua no histórico. Ligue **secret scanning e push
protection** em todos os repositórios — é gratuito em repositório público e
bloqueia o push antes de o token entrar no histórico.

### 2.2 Reusable workflows moram em `.github/workflows/` do DevOps

Correção à estrutura originalmente proposta: um reusable workflow **precisa**
estar em `.github/workflows/` do repositório que o hospeda. Uma pasta
`workflows/` na raiz não é reconhecida pelo `workflow_call`.

Com o DevOps público, qualquer repositório da organização consegue chamá-lo sem
configuração adicional de acesso.

### 2.3 Website na Vercel, sem Docker em produção

O Website é um bundle estático. Conteinerizá-lo significaria consumir horas de
instância do Render, sofrer cold start e manter um `nginx.conf` — sem ganho.
A Vercel entrega deploy automático, CDN e **preview por Pull Request**, que é
genuinamente útil para revisar mudança de front-end.

O Dockerfile continua existindo no repositório para o Compose local e para
demonstrar conteinerização, mas não é o caminho de produção.

### 2.4 O banco não fica no Render

O Postgres gratuito do Render expira 30 dias depois de criado e só permite uma
instância por workspace — não atravessa um semestre com dois ambientes.

**Escolha do grupo: Neon.** O plano gratuito não tem prazo de validade e
permite múltiplos projetos, cada um com **branching de banco** — um recurso que
resolve de saída o problema que outras opções gratuitas têm de sustentar dois
ambientes ao mesmo tempo.

Modelo adotado: **um projeto Neon**, com duas branches de banco —
`qa` e `prod`. Cada branch se comporta como um banco independente (schema e
dados próprios), mas nasce de um snapshot compartilhado, o que facilita
recriar QA a partir de PROD quando for útil para reproduzir um bug. Isso
resolve, sem precisar de duas contas nem de dois bancos lógicos manuais, o
mesmo isolamento que eu tinha desenhado como pendência quando o banco era o
Aiven.

Único ponto de atenção: como o Neon do plano gratuito também aplica
**scale-to-zero** — a instância de computação hiberna depois de alguns minutos
sem uso —, o primeiro acesso após um período parado tem uma latência maior
(volta em segundos, não minutos, mas é perceptível). Vale religar antes de uma
demonstração, pelo mesmo motivo do Render.

Para o Chatbot, o Render não oferece MongoDB gerenciado: **MongoDB Atlas M0**
(gratuito, 512 MB), com dois bancos lógicos — `volta_qa` e `volta_prod`.

### 2.5 Imagens do GHCR públicas

Storage gratuito, Render sem credencial de registry e Compose funcionando sem
login. O preço é que **tudo dentro da imagem é público** — o que transforma
várias recomendações da seção 13 em requisitos.

---

## 3. Responsabilidade de cada repositório

| Repositório | Produz | CI | CD |
|---|---|---|---|
| **API** | `ghcr.io/app-volta/api` | Maven build + testes | Render QA (auto) / PROD (com aprovação) |
| **Mobile** | APK como artifact | Gradle build + testes + lint | — |
| **Chatbot** | `ghcr.io/app-volta/chatbot` | Ruff + pytest | Render QA (auto) / PROD (com aprovação) |
| **Website** | Bundle estático | Lint + tsc + build | Vercel: preview (develop) / produção (main) |
| **Database** | Scripts SQL + `.drawdb` | Execução em Postgres efêmero | — |
| **DevOps** | Reusable workflows, Compose, docs | Lint de YAML | — |
| **volta-landing-page** | Página do 1º ano | — | Fora do ruleset e desta arquitetura |

Detalhamentos que importam:

**API.** Expõe `/actuator/health` — não é enfeite: é o health check do Render e
o alvo do smoke test pós-deploy. A porta vem de variável de ambiente
(`SERVER_PORT`), porque o Render injeta a porta em que o container deve ouvir.

**Mobile.** Publica o APK de debug como artifact do workflow. Os colegas e o
professor baixam o app pela aba Actions sem precisar compilar. Não é publicação
em loja — é distribuição interna, e resolve um problema real de demonstração.

**Database.** Sem deploy e sem migrations. Ganha uma verificação que custa quase
nada: subir um Postgres descartável dentro do runner e executar os scripts na
ordem. Erro de sintaxe no DDL, FK apontando para tabela inexistente ou insert
violando constraint fazem o CI falhar antes de a API tentar usar aquele schema.

**Website.** O Vite embute as variáveis `VITE_*` no bundle **em tempo de
build**. Logo, a URL da API é configurada no painel da Vercel, e **nenhum
segredo pode ser uma variável `VITE_*`** — ela fica visível no JavaScript
entregue ao navegador.

**DevOps.** Não hospeda código de aplicação. Regra para decidir se algo pertence
ao DevOps: *"se este arquivo precisar mudar quando o código da aplicação mudar,
ele não é do DevOps"*.

**volta-landing-page.** Repositório dos integrantes do 1º ano, que não têm code
review como requisito e fazem merge direto pelo terminal. Está explicitamente
excluído do ruleset da organização (seção 6) e não participa desta esteira.

---

## 4. Estratégia de branches

```text
main     ──●───────────────●──────────────●──────►  PROD
            ╲             ╱ ╲            ╱
develop  ────●───●───●───●───●───●───●──●─────────►  QA
              ╲ ╱     ╲ ╱         ╲ ╱
feat/12-login ●       ●            ●
```

### Ajuste no padrão de nomes

O regex originalmente proposto exigia exatamente dois dígitos
(`[0-9]{2}`), o que rejeita a issue #103. Padrão adotado:

```regex
^(feat|fix|refactor|chore|test|docs)/[0-9]{1,4}-[a-z0-9._-]+$
```

Também força o descritivo em minúsculas com hífen, evitando
`feat/12-Login_Tela FINAL`. Quem verifica é o job `validate-pr`.

### Hotfix

Sem branches `release/*`, ainda falta responder: *e quando PROD quebra e
`develop` já tem trabalho não validado?*

```text
main ──●──────────────●──►
        ╲            ╱ ╲
         ● fix/NN-x ─┘   ╲ (back-merge obrigatório)
                          ▼
develop ──────────────────●──►
```

1. Criar `fix/NN-descricao` **a partir de `main`**.
2. PR para `main`, com os mesmos checks e aprovação.
3. Depois do merge, **abrir imediatamente um PR de `main` para `develop`**. Sem
   esse passo, o próximo merge `develop → main` reintroduz o bug.

É o único caso em que uma branch não sai de `develop`, e precisa estar
documentado antes de acontecer às 23h da véspera da entrega.

---

## 5. Fluxo de Pull Requests

```text
 Issue #12 criada e atribuída
        │
        ├─► branch feat/12-login (a partir de develop)
        │
        ├─► commits (Conventional Commits)
        │
        ├─► PR para develop, com "Closes #12" no corpo
        │        │
        │        ├─ [auto] validate-pr  → nome da branch, base, título
        │        ├─ [auto] build-test   → build, testes, lint
        │        ├─ [auto] revisor atribuído via CODEOWNERS
        │        │
        │        ├─ 1 aprovação obrigatória (ruleset)
        │        └─ conversas resolvidas
        │
        └─► squash merge em develop  →  dispara CD de QA
```

Três pontos que fazem diferença:

- **`Closes #12` no corpo do PR** fecha a issue no merge e mantém a
  rastreabilidade issue ↔ branch ↔ PR ↔ commit.
- **PR de feature só pode ter `develop` como base** — verificado pelo
  `validate-pr`.
- **Um PR, uma issue.** PRs que resolvem três coisas são impossíveis de revisar
  e destroem a distribuição de commits entre colaboradores, que é critério de
  avaliação.

Como o code review é requisito avaliado, o template de PR ganha peso. Checklist
sugerido:

```markdown
- [ ] O CI passou nesta branch
- [ ] Testei localmente
- [ ] A issue vinculada está coberta por completo
```

---

## 6. Proteção de branches e ruleset

A proteção é configurada **uma vez, no nível da organização**, e vale para todos
os repositórios — em vez de repetir a configuração seis vezes e esquecer uma.

### Pré-requisito: nomes de check padronizados

Um ruleset de organização exige o **mesmo nome de check** em todos os
repositórios alvo. Por isso todo workflow usa os mesmos nomes de job:

```text
build-test
validate-pr
```

Ao chamar um reusable workflow, o nome que aparece na lista de checks é
`job-chamador / job-chamado` — por exemplo, `validate-pr / validate-pr`. Rode o
workflow uma vez, copie o nome exato da interface e só então marque como
obrigatório.

### Ruleset `develop`

| Regra | Valor |
|---|---|
| Pull Request obrigatório | Sim |
| Aprovações necessárias | 1 |
| Descartar aprovações em novo push | Não |
| Checks obrigatórios | `validate-pr / validate-pr`, `build-test` |
| Exigir branch atualizada antes do merge | Não |
| Resolução de conversas | Sim |
| Bloquear force push | Sim |
| Bloquear exclusão | Sim |

### Ruleset `main`

| Regra | Valor |
|---|---|
| Pull Request obrigatório | Sim |
| Aprovações necessárias | 1 |
| Descartar aprovações em novo push | **Sim** |
| Exigir revisão de CODEOWNERS | **Sim** |
| Checks obrigatórios | `validate-pr / validate-pr`, `build-test` |
| Exigir branch atualizada antes do merge | **Sim** |
| Resolução de conversas | Sim |
| Bloquear force push | Sim |
| Bloquear exclusão | Sim |

### Por que 1 aprovação e não 2

A equipe tem, em vários repositórios, uma ou duas pessoas com contexto real. O
GitHub já impede que o autor aprove o próprio PR. Exigir 2 aprovações num
repositório com 2 pessoas significa que **nenhum PR consegue ser mergeado** — e
a saída inevitável é alguém desligar a regra às pressas, o que é pior do que
nunca tê-la ligado. Uma aprovação obrigatória é uma regra que a equipe consegue
cumprir.

Em `main`, o rigor extra vem de outro lugar: revisão obrigatória do CODEOWNER,
descarte de aprovações em novo push e aprovação manual do Environment de
produção.

### Excluir o `volta-landing-page` do ruleset

Os integrantes do 1º ano não têm code review como requisito e fazem merge direto
pelo terminal. Como o ruleset é de organização, ele precisa ser excluído
explicitamente.

Em **Organization settings → Repository → Rulesets → (seu ruleset) → Targeting
criteria**:

```text
Add a target → Include by pattern → *
Add a target → Exclude by pattern → volta-landing-page
```

Alternativas, se o cenário crescer:

| Forma | Como | Quando |
|---|---|---|
| **Exclude by pattern** | `*` incluído, `volta-landing-page` excluído | Recomendado agora |
| Padrão coringa | Excluir `volta-landing-*` | Se o 1º ano criar mais repositórios |
| Only selected repositories | Marcar manualmente os 6 do 2º ano | Lista explícita, exige editar a cada repo novo |
| Custom property | Propriedade `code-review` e filtro por ela | Se a organização crescer bastante |

Recomendação: use `volta-landing-*` como padrão de exclusão desde já. Cobre o
repositório atual e os futuros do 1º ano sem exigir nova intervenção.

### Uma armadilha a evitar

**Filtros `paths` em check obrigatório.** Se um workflow obrigatório é pulado
por `paths-ignore`, o GitHub mostra o check como "pendente" para sempre e o PR
**nunca** pode ser mergeado. Não use filtro de caminho em workflow que é check
obrigatório.

---

## 7. CODEOWNERS

Com os repositórios públicos, o CODEOWNERS funciona: ele atribui revisor
automaticamente e, combinado com "Exigir revisão de CODEOWNERS" no ruleset de
`main`, torna a aprovação da pessoa certa obrigatória.

Times sugeridos na organização:

```text
@app-volta/backend    @app-volta/mobile    @app-volta/frontend
@app-volta/data       @app-volta/ai        @app-volta/devops
```

Arquivo `.github/CODEOWNERS` em cada repositório. Exemplo para a **API**:

```text
# Dono padrão de todo o repositório
*                       @app-volta/backend

# Infraestrutura e pipeline são responsabilidade do time de DevOps
/.github/workflows/     @app-volta/devops
/Dockerfile             @app-volta/devops
/.dockerignore          @app-volta/devops

# Contrato do banco: entidades JPA envolvem a Modelagem de Dados
/src/main/java/**/entity/    @app-volta/backend @app-volta/data
```

A linha de `/.github/workflows/` é a mais relevante para o papel de DevOps:
registra que qualquer alteração na pipeline, em qualquer repositório, passa
pelo time responsável por ela.

Três detalhes práticos:

1. CODEOWNERS só funciona se o time tiver **permissão de escrita** no
   repositório.
2. O time DevOps precisa de **pelo menos duas pessoas** — com uma só, você fica
   bloqueado ao alterar um workflow, porque ninguém pode aprovar o próprio PR.
3. Regras posteriores sobrescrevem as anteriores: a linha `*` fica sempre no
   topo.

---

## 8. Ambientes QA e PROD

```text
develop  ──►  Environment "qa"    ──►  Render: volta-<app>-qa    ──►  Neon branch qa / volta_qa
                                       Vercel: preview da branch develop

main     ──►  Environment "prod"  ──►  Render: volta-<app>-prod  ──►  Neon branch prod / volta_prod
                                       Vercel: produção
```

### Por que GitHub Environments

Com repositórios públicos, os Environments resolvem três problemas sem
ferramenta extra:

1. **Secrets por ambiente.** `RENDER_DEPLOY_HOOK` existe com o mesmo nome nos
   dois ambientes, apontando para serviços diferentes. O workflow é um só; o
   valor muda conforme o `environment:` declarado no job.
2. **Aprovação manual antes de produção.** No environment `prod`, marque
   *Required reviewers*. O deploy fica parado esperando um clique, mesmo com o
   merge em `main` já feito. É o portão de produção.
3. **Restrição de branch.** `prod` só aceita deploy a partir de `main`; `qa` só
   a partir de `develop`. Mesmo que alguém dispare o workflow manualmente da
   branch errada, o GitHub recusa.

Bônus: a aba *Deployments* do repositório passa a mostrar o histórico de
implantações com commit, autor e horário — documentação automática do que subiu
e quando.

### Nomenclatura dos serviços

```text
volta-api-qa        volta-api-prod
volta-chatbot-qa    volta-chatbot-prod
```

### Orçamento de horas do Render

O Render concede 750 horas de instância gratuita por mês, por workspace, e
serviços hibernados não consomem. Como um serviço gratuito hiberna após 15
minutos sem tráfego, o consumo é proporcional ao uso:

| Cenário | Consumo | Cabe? |
|---|---|---|
| 4 serviços acordados ~2 h/dia | ~240 h | Sim, com folga |
| 4 serviços acordados ~6 h/dia | ~720 h | No limite |
| 4 serviços acordados 24/7 | ~2.920 h | **Não — suspensão** |

Com o Website na Vercel, sobram apenas 4 serviços no Render. Duas regras:

- **Nunca use serviço de ping/uptime para evitar o cold start.** Isso mantém os
  containers acordados e queima a cota da organização inteira em poucos dias.
- **Na apresentação, acorde os serviços 5 minutos antes.** O primeiro acesso a
  um serviço hibernado leva cerca de um minuto. É o tipo de detalhe que estraga
  uma demonstração boa. O mesmo vale para o Neon, cuja instância de computação
  também entra em scale-to-zero por inatividade.

---

## 9. Estratégia de GitHub Actions

### A regra de decisão: workflow local ou reusable no DevOps?

> **O que muda junto, mora junto.**

| Pergunta | Se sim → |
|---|---|
| Depende da árvore de código do repositório (compilar, testar, lintar)? | Workflow local |
| É a mesma coisa em 2+ repositórios, mudando só parâmetros? | Reusable no DevOps |
| Mexe com registry, credenciais ou plataforma de deploy? | Reusable no DevOps |
| Uma quebra aqui deveria parar os 6 repositórios de uma vez? | Pense duas vezes |

| Componente | Onde vive | Por quê |
|---|---|---|
| Build + teste da API (Maven) | Local na API | Muda quando o `pom.xml` muda |
| Build + teste do Mobile (Gradle) | Local no Mobile | Idem |
| Build + teste do Website (npm) | Local no Website | Idem |
| Build Docker + push GHCR | **Reusable no DevOps** | Idêntico para API e Chatbot |
| Deploy no Render | **Reusable no DevOps** | Idêntico para os dois serviços |
| Validação de PR | **Reusable no DevOps** | Regra da organização, não da aplicação |
| Limpeza do GHCR | Workflow próprio do DevOps | Agendado, não é chamado por ninguém |

A tentação errada é centralizar o CI das linguagens no DevOps ("assim não
duplica"). Não duplica mesmo, mas cria duas patologias: mudar o `pom.xml` passa
a exigir PR em outro repositório, e um erro no workflow de build derruba os seis
repositórios ao mesmo tempo. O build de Maven, Gradle, npm e pip não é a mesma
coisa parametrizada — é código diferente.

Com o DevOps público, **todos os repositórios da organização conseguem chamar
os reusable workflows**, sem configuração de acesso.

### Convenções obrigatórias

```yaml
jobs:
  build-test:          # nome padronizado — é o que o ruleset exige

permissions:
  contents: read       # mínimo; eleva só onde precisa

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true
```

Exceção ao `cancel-in-progress`: nos jobs de **deploy**, use `false`. Cancelar
um deploy no meio deixa o ambiente em estado indefinido.

### Versionamento dos reusable workflows

Referencie por tag, nunca por `main` móvel:

```yaml
uses: app-volta/DevOps/.github/workflows/reusable-docker-build-push.yml@v1
```

Crie a tag `v1` no DevOps e mova-a quando quiser propagar mudanças compatíveis.
Sem isso, um commit errado no DevOps quebra os outros repositórios no mesmo
instante.

---

## 10. Workflows por repositório

### API e Chatbot

```text
ci.yml       on: pull_request [develop, main] + push [develop, main]
             jobs: validate-pr (só em PR) | build-test

cd.yml       on: push [develop, main] + workflow_dispatch
             jobs: build-test → docker (reusable) → deploy (reusable)
                   environment resolvido pela branch: develop→qa, main→prod
```

O portão de produção não é mais um workflow separado: é o *Required reviewer*
do Environment `prod`, que segura o job de deploy até alguém aprovar.

### Website

```text
ci.yml       on: pull_request [develop, main] + push [develop, main]
             jobs: validate-pr | build-test (lint, tsc, build)
```

Sem `cd.yml`: a integração nativa da Vercel cuida do deploy (seção 17).

### Mobile

```text
ci.yml       jobs: validate-pr | build-test → upload do APK
```

### Database

```text
ci.yml       jobs: validate-pr | build-test (scripts em Postgres efêmero)
```

### DevOps

```text
.github/workflows/
├── reusable-validate-pr.yml        (workflow_call)
├── reusable-docker-build-push.yml  (workflow_call)
├── reusable-render-deploy.yml      (workflow_call)
├── ci.yml                          (lint de YAML e do Compose)
└── ghcr-cleanup.yml                (schedule mensal + workflow_dispatch)
```

### Arquivos de apoio

```text
.github/CODEOWNERS
.github/dependabot.yml
.github/pull_request_template.md   ← herdado do repo .github da org
```

O repositório `.github` da organização fornece templates de PR e issue como
padrão para os repos sem os seus próprios. CODEOWNERS e Dependabot **não** são
herdados — precisam existir em cada repositório.

---

## 11. Workflows reutilizáveis no DevOps

### 11.1 `reusable-validate-pr.yml`

Sem inputs — lê o contexto do PR herdado do workflow chamador. Verifica:

- nome da branch contra o regex da seção 4;
- base do PR permitida (feature → `develop`; `develop` → `main`; hotfix
  `fix/*` vindo de `main` → `main`);
- título do PR em Conventional Commits — importa porque o squash merge usa o
  título do PR como mensagem de commit.

### 11.2 `reusable-docker-build-push.yml`

```yaml
inputs:   image-name, context, dockerfile, push, moving-tag
outputs:  image-tag        # sha-a1b2c3d
```

Login no GHCR com `GITHUB_TOKEN`, build para `linux/amd64`, cache de camadas
via `type=gha`, tags da seção 16, labels OCI e push condicional.

### 11.3 `reusable-render-deploy.yml`

```yaml
inputs:   environment, image-name, image-tag, health-url, health-retries
secrets:  render-deploy-hook
```

Declara `environment: ${{ inputs.environment }}` — é esse job que fica parado
esperando a aprovação em produção. Aciona o deploy hook fixando a tag exata,
aguarda o health check e escreve o resumo da implantação.

### 11.4 `ghcr-cleanup.yml`

Agendado mensalmente + `workflow_dispatch`. Remove versões sem tag e mantém as
10 mais recentes. **Nunca** toca em `latest` nem em `qa`.

Requer um PAT com escopo `delete:packages` no secret `GHCR_CLEANUP_TOKEN`: o
`GITHUB_TOKEN` do DevOps não tem permissão sobre pacotes cujo repositório de
origem é outro.

---

## 12. Pipelines de build, testes e qualidade

### API (Java 21 / Spring Boot / Maven)

```text
checkout → setup-java (temurin 21, cache: maven) → mvn -B verify
        → upload do relatório surefire
```

`mvn -B verify` cobre num comando só dependências, compilação, testes e
empacotamento. O cache do Maven vem pronto no `setup-java`.

Qualidade proporcional: **Spotless ou Checkstyle** em modo verificação.
Formatação consistente reduz conflito bobo de merge e é a verificação com melhor
relação custo/benefício num trabalho em grupo. SonarQube fica de fora: exige
servidor ou conta na nuvem e não gera ação que o grupo vá tomar.

### Mobile (Android / Java / Gradle)

```text
checkout → setup-java 17 → setup-gradle (cache)
        → assembleDebug → testDebugUnitTest → lintDebug
        → upload do APK
```

O SDK do Android já vem no runner. Testes instrumentados (emulador) ficam fora
do CI: lentos e instáveis.

### Chatbot (Python / FastAPI)

```text
checkout → setup-python 3.12 (cache: pip) → pip install → ruff check → pytest
```

O Ruff substitui flake8 + isort + black com uma ferramenta. **Não chame a LLM
real no CI** — torna o pipeline lento, não determinístico e consome cota paga.

### Website (TypeScript / React / Vite)

```text
checkout → setup-node 20 (cache: npm) → npm ci → npm run lint
        → npx tsc --noEmit → npm run build
```

`npx tsc --noEmit` merece destaque: o Vite transpila TypeScript **sem verificar
tipos**. Sem esse passo, erro de tipagem passa direto e só aparece em runtime.

### Database (SQL)

```text
checkout → service container postgres:16
        → 01-schema.sql → 02-views.sql → 03-procedures.sql
          → 04-triggers.sql → 05-dataload.sql
        → consultas de sanidade
```

O banco nasce e morre dentro do runner. Exige uma convenção: **prefixo numérico
de ordem nos arquivos** — sem ela não há como automatizar, nem como o Compose
montar o banco local a partir dos mesmos artefatos.

---

## 13. Segurança e secrets

### Ponto de atenção 1: imagens públicas

A decisão de publicar as imagens do GHCR como públicas resolve storage e
credencial, mas transfere uma responsabilidade: **tudo dentro da imagem é
público**. Regras que passam a ser obrigatórias:

- `.dockerignore` **precisa** excluir `.env`, `*.pem`, `*.key`,
  `application-local.yml`;
- `application.yml` só pode conter placeholders (`${DB_PASSWORD}`), nunca
  valores;
- nenhuma chave de API, senha ou secret em `ENV` ou `ARG` do Dockerfile;
- um JAR é decompilável — a imagem entrega o código compilado a quem baixar.

Teste de cinco minutos que vale fazer uma vez:

```bash
docker run --rm -it ghcr.io/app-volta/api:latest sh
```

### Ponto de atenção 2: repositórios públicos

Histórico público. Um secret commitado e removido depois **continua no
histórico**. Ligue **secret scanning e push protection** em todos os
repositórios — gratuito em repo público, e bloqueia o push antes de o token
entrar no histórico.

### O que fica ligado, custo próximo de zero

- **`permissions` mínimas em todo workflow**, elevando só onde necessário.
- **Dependabot** para maven, gradle, npm, pip, docker e github-actions.
- **Pin de actions**: `@v4` para oficiais, SHA completo para terceiros.
- **CodeQL** — em repositório público é um toggle na interface e cobre Java,
  Python e JavaScript. Opcional, mas é o item de segurança demonstrável mais
  barato disponível.

Fora do escopo, com justificativa: DAST, assinatura de imagem, SBOM e scan de
container. São boas práticas corporativas que não geram ação acionável aqui.

### Classificação da informação

| Informação | Classificação | Onde fica |
|---|---|---|
| `RENDER_DEPLOY_HOOK` | **Secret de Environment** (`qa` e `prod`) | GitHub |
| `GHCR_CLEANUP_TOKEN` (PAT) | Secret de repositório | GitHub (DevOps) |
| Senha do Postgres (Neon) | Secret | Painel do Render |
| String de conexão MongoDB Atlas | Secret | Painel do Render |
| `JWT_SECRET` | Secret | Painel do Render (**diferente por ambiente**) |
| Chave de API da LLM | Secret | Painel do Render |
| `GITHUB_TOKEN` | Automático | Gerado pelo Actions a cada execução |
| URL pública da API por ambiente | Variable | `vars` do Environment |
| `VITE_API_BASE_URL` | Variable (**nunca secret**) | Painel da Vercel, por ambiente |
| Versões de Java/Node/Python | Versionado no Git | Dentro do workflow |
| Dockerfiles, Compose, render.yaml | Versionado no Git | Repositório |
| `.env.example` (chaves sem valores) | Versionado no Git | Repositório |
| `.env` (com valores) | **Nunca versionado** | Máquina local |

### Onde o secret realmente mora

**Os secrets da aplicação não ficam no GitHub.** Senha de banco, chave de LLM e
`JWT_SECRET` são variáveis de ambiente no painel do Render, porque quem precisa
deles é o container em execução — não o pipeline. O GitHub guarda apenas o que
o *pipeline* precisa: essencialmente a URL do deploy hook.

Um `JWT_SECRET` diferente entre QA e PROD não é preciosismo: garante que um
token emitido em QA não seja aceito em produção.

---

## 14. Estratégia de Docker

### Princípios

- **Multi-stage sempre**: o compilador não vai para produção.
- **`linux/amd64` obrigatório** — exigência do Render. Quem desenvolve em Mac
  com Apple Silicon gera `arm64` por padrão e o deploy falha.
- **Usuário não-root** no estágio final.
- **Porta por variável de ambiente**: o Render injeta `PORT`.
- **`.dockerignore` sempre** — com imagem pública, também é controle de
  segurança.

### API

Multi-stage com `maven:3.9-eclipse-temurin-21` no build e
`eclipse-temurin:21-jre-alpine` no runtime. O `COPY pom.xml` antes do `COPY src`
não é detalhe: enquanto o `pom.xml` não mudar, o Docker reaproveita a camada de
dependências.

Resultado esperado: ~200 MB, contra ~600 MB com JDK completo.

### Chatbot

`python:3.12-slim`, `pip install --no-cache-dir`, usuário não-root, e
`uvicorn --host 0.0.0.0 --port ${PORT:-8000}`.

### Website

Dockerfile apenas para o Compose local (node build → nginx). Não vai para
produção: quem publica é a Vercel.

### Rastreabilidade sem processo de release

```dockerfile
LABEL org.opencontainers.image.source="https://github.com/app-volta/API"
LABEL org.opencontainers.image.revision="${GIT_SHA}"
```

O label `source` vincula o pacote no GHCR ao repositório, fazendo-o aparecer na
página do repo e herdar permissões.

---

## 15. Estratégia de Docker Compose

Arquivo em `DevOps/compose/docker-compose.yml`.

| Serviço | No Compose? | Por quê |
|---|---|---|
| `postgres` | **Sim** | Banco local, inicializado com os scripts do repo Database |
| `mongo` | **Sim** | Necessário ao Chatbot |
| `api` | **Sim** (profile `apps`) | Quem trabalha no Mobile precisa da API sem instalar Java |
| `chatbot` | **Sim** (profile `apps`) | Idem |
| `website` | **Não** | `npm run dev` local é mais rápido e tem hot reload |
| `pgadmin` / `mongo-express` | Opcional (profile `tools`) | Útil, não essencial |
| Mobile | **Não** | Android precisa de SDK e emulador |
| Proxy reverso | **Não** | Render e Vercel já resolvem TLS e roteamento |

```bash
docker compose up postgres mongo      # só os bancos (dev de API roda na IDE)
docker compose --profile apps up      # backend completo (dev de Mobile)
docker compose --profile tools up     # + interfaces de administração
```

### Fonte única de verdade do schema

O Postgres do Compose é inicializado com **os mesmos scripts do repositório
Database**, montados em `/docker-entrypoint-initdb.d` — o Postgres executa em
ordem alfabética tudo o que estiver nessa pasta na primeira inicialização.

Convenção: repositórios clonados lado a lado.

```text
volta/
├── API/
├── Chatbot/
├── Database/
└── DevOps/        ← docker compose roda daqui
```

```yaml
volumes:
  - ../../Database/scripts:/docker-entrypoint-initdb.d:ro
```

### Segundo arquivo: rodar sem compilar nada

`docker-compose.ghcr.yml` usa as imagens já publicadas:

```yaml
services:
  api:
    image: ghcr.io/app-volta/api:qa
```

Como as imagens são públicas, funciona **sem login e sem clonar nada**. Um
`docker compose -f docker-compose.ghcr.yml up` e o backend sobe — inclusive na
máquina do professor, na avaliação.

---

## 16. Estratégia de GHCR

### Nomenclatura

```text
ghcr.io/app-volta/api
ghcr.io/app-volta/chatbot
```

Sem `website` (vai para a Vercel). Sem sufixo de ambiente no nome: **a mesma
imagem serve QA e PROD** — é o que garante que produção rode o artefato
validado. Ambiente é *tag* e *serviço*, não imagem diferente.

### Tags

| Tag | Muda? | Para quê |
|---|---|---|
| `sha-a1b2c3d` | **Imutável** | A verdade. Todo deploy fixa uma dessas |
| `qa` | Móvel | Aponta para o que está em QA |
| `latest` | Móvel | Aponta para o que está em PROD |

O deploy **sempre** referencia `sha-*`; as tags móveis são conveniência para
humanos e para o Compose. É isso que torna o rollback trivial e o histórico
auditável.

Semantic versioning fica de fora: não há processo de release, e versão que
ninguém incrementa com critério é pior que não ter versão.

### Quando construir e quando publicar

| Evento | Build? | Push? |
|---|---|---|
| PR para `develop`/`main` | Não | Não |
| Merge em `develop` | Sim | `sha-*` + `qa` |
| Merge em `main` | Sim | `sha-*` + `latest` |

Não construir imagem no PR mantém o feedback rápido: o CI já compila e testa, e
o build Docker só é útil depois do merge.

### Autenticação e permissões

Publicar exige apenas:

```yaml
permissions:
  contents: read
  packages: write
```

Consumir não exige nada: as imagens são públicas.

### Dois passos manuais, uma vez só

1. Em *Organization settings → Packages*, permitir a criação de pacotes
   **públicos**.
2. O primeiro push cria o pacote como **privado**. Vá em *Package settings →
   Change visibility → Public*, uma vez por imagem.

Se esquecer o passo 2, o deploy no Render falha com erro de pull.

### Limpeza

Workflow mensal: apaga versões sem tag e mantém as ~10 tags `sha-*` mais
recentes.

Cuidado crítico: o Render **não guarda imagens já baixadas** — ele puxa do
registry a cada deploy, e também quando o serviço volta da hibernação. Apagar
uma tag em uso **derruba o serviço no próximo restart**. Nunca apague `latest`,
nunca apague `qa`, e mantenha as `sha-*` recentes, que são o alvo de rollback.

---

## 17. Deploy: Render e Vercel

### 17.1 API e Chatbot — Render, image-backed

| | Git-backed (Render constrói) | **Image-backed (GHCR)** |
|---|---|---|
| Onde a imagem é construída | No Render | No GitHub Actions |
| Artefato testado = implantado | Não garantido | **Garantido** |
| Builds por entrega | 2 | 1 |
| Usa GHCR | Não | Sim |
| Rollback para versão arbitrária | Limitado | Por tag `sha-*` |

Serviços baseados em imagem **não reimplantam sozinhos** quando a tag recebe
imagem nova. O deploy é disparado pelo **deploy hook**, que aceita `imgURL` para
puxar uma tag ou digest específicos:

```bash
curl -fsS -X POST \
  "${RENDER_DEPLOY_HOOK}&imgURL=ghcr.io%2Fapp-volta%2Fapi%3Asha-a1b2c3d"
```

O serviço fica configurado com `latest`, mas cada deploy aponta para a `sha-*`
daquele commit. A URL precisa estar codificada (`/` → `%2F`, `:` → `%3A`).

**Smoke test.** Disparar o hook retorna sucesso assim que o Render *aceita* o
pedido — não quando a aplicação está de pé. Sem verificação, o workflow fica
verde com o deploy falhando. O job termina consultando o health check até 30
vezes, a cada 10 segundos.

**`render.yaml`.** Como nada foi criado ainda no Render, dá para provisionar a
partir de um Blueprint versionado em `DevOps/render/render.yaml`. Declare
serviços, região, health check path e variáveis com `sync: false` (o Render
pede o valor sem versioná-lo).

### 17.2 Website — Vercel

| Item | Valor |
|---|---|
| Production Branch | `main` |
| Preview | automático em `develop` e em cada PR |
| Framework Preset | Vite |
| Build Command | `npm run build` |
| Output Directory | `dist` |
| Env (Production) | `VITE_API_BASE_URL` → API de PROD |
| Env (Preview) | `VITE_API_BASE_URL` → API de QA |

O mapeamento QA/PROD sai de graça: `develop` gera preview com URL estável,
`main` publica em produção. Como o ruleset bloqueia merge com CI falhando, o
deploy automático da Vercel é seguro — nada chega em `main` sem passar pelo CI.

Rollback: a Vercel mantém todos os deployments; basta promover um anterior.

Ponto de atenção: o plano Hobby é para uso não comercial. Projeto acadêmico se
enquadra.

---

## 18. Estrutura de diretórios do DevOps

```text
DevOps/
├── .github/
│   ├── workflows/
│   │   ├── reusable-validate-pr.yml
│   │   ├── reusable-docker-build-push.yml
│   │   ├── reusable-render-deploy.yml
│   │   ├── ci.yml
│   │   └── ghcr-cleanup.yml
│   ├── CODEOWNERS
│   └── dependabot.yml
│
├── compose/
│   ├── docker-compose.yml
│   ├── docker-compose.ghcr.yml
│   ├── .env.example
│   └── README.md
│
├── docker/                      # templates de referência
├── render/
│   ├── render.yaml
│   └── configuracao-servicos.md
├── vercel/
│   └── configuracao-website.md
├── scripts/
│   ├── setup-local.sh
│   ├── deploy-manual.sh
│   └── check-health.sh
│
├── docs/
│   ├── 01-arquitetura-cicd.md   ← este documento
│   ├── 02-ambientes.md
│   ├── 03-secrets.md
│   ├── 04-runbook-deploy.md
│   ├── 05-padroes-git.md
│   └── 99-evolucao-kubernetes.md
│
└── README.md
```

### Modificações em relação à estrutura original

| Mudança | Motivo |
|---|---|
| `workflows/` → `.github/workflows/` | Requisito técnico do `workflow_call` |
| `docker-compose/` → `compose/` | Evita `docker-compose/docker-compose.yml` |
| `kubernetes/` removido | Não será implementado; vira `docs/99-evolucao-kubernetes.md` |
| `docker/` vira pasta de templates | Dockerfile de produção mora junto do código que ele constrói |
| `vercel/` adicionado | O Website não é Render; a configuração precisa estar versionada |

---

## 19. Fluxo completo em diagrama

```text
╔══════════════════════════════════════════════════════════════════════════╗
║ DESENVOLVIMENTO                                                          ║
╚══════════════════════════════════════════════════════════════════════════╝
  Issue #12  ──►  git switch -c feat/12-login  (a partir de develop)
                            │  commits + push
                            ▼
                  ┌──────────────────────┐
                  │  Pull Request        │
                  │  base: develop       │
                  └──────────┬───────────┘
╔════════════════════════════▼═════════════════════════════════════════════╗
║ CI — on: pull_request                                                    ║
╚══════════════════════════════════════════════════════════════════════════╝
        validate-pr                    build-test
   ┌────────────────────┐      ┌────────────────────────────┐
   │ nome da branch     │      │ checkout                   │
   │ base permitida     │  ||  │ setup + cache              │
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
║ CD QA — on: push develop                                                 ║
╚══════════════════════════════════════════════════════════════════════════╝
   build-test  ──►  docker-build-push  ──►  deploy (environment: qa)
                    ┌──────────────────┐    ┌───────────────────────────┐
                    │ login GHCR       │    │ deploy hook + imgURL      │
                    │ build amd64      │    │   fixando sha-a1b2c3d     │
                    │ tags: sha-*, qa  │    │ smoke test em /health     │
                    │ push             │    │ summary                   │
                    └──────────────────┘    └─────────────┬─────────────┘
                                                          ▼
                                          Render: volta-api-qa
                                          Neon branch qa / volta_qa

                             │  validação manual em QA (checklist)
                             ▼
              ┌──────────────────────────────────────┐
              │ PR: develop ──► main                 │
              │ merge commit, NUNCA squash           │
              │ + CODEOWNER + branch atualizada      │
              └──────────────────┬───────────────────┘
                                 ▼
╔══════════════════════════════════════════════════════════════════════════╗
║ CD PROD — on: push main                                                  ║
╚══════════════════════════════════════════════════════════════════════════╝
   build-test  ──►  docker-build-push  ──►  ⏸ APROVAÇÃO MANUAL
                    (tags: sha-*, latest)   (Environment prod:
                                             required reviewers)
                                                    │
                                                    ▼
                                        deploy hook + smoke test
                                                    │
                                                    ▼
                                        Render: volta-api-prod
                                        Neon branch prod / volta_prod

╔══════════════════════════════════════════════════════════════════════════╗
║ WEBSITE                                                                  ║
╚══════════════════════════════════════════════════════════════════════════╝
   PR → CI (bloqueante) → Vercel preview do PR
                        → merge develop → preview de QA
                        → merge main    → produção

╔══════════════════════════════════════════════════════════════════════════╗
║ FORA DA ESTEIRA DE DEPLOY                                                ║
╚══════════════════════════════════════════════════════════════════════════╝
  Mobile             → CI + APK como artifact.  Sem CD.
  Database           → CI em Postgres efêmero.  Sem CD.
  DevOps             → CI de YAML + limpeza mensal do GHCR.
  volta-landing-page → fora do ruleset e desta arquitetura.
```

---

## 20. Regras de merge

| De → Para | Estratégia | Aprovação | Checks |
|---|---|---|---|
| `feat\|fix\|...` → `develop` | **Squash** | 1 | `validate-pr`, `build-test` |
| `develop` → `main` | **Merge commit** | 1 + CODEOWNER | idem |
| `fix/*` (de `main`) → `main` | Squash | 1 + CODEOWNER | idem |
| Push direto | **Bloqueado pelo ruleset** | — | — |

### Por que squash de feature para develop

O histórico de `develop` fica com um commit por issue, legível e reversível. Os
commits intermediários ("wip", "corrige typo") somem — o que é bom, porque não
têm valor histórico. E como a distribuição de commits entre colaboradores é
critério de avaliação, um commit limpo por issue conta mais a favor do que
quarenta commits ruidosos.

### Por que NUNCA squash de develop para main

O squash cria um commit **novo** em `main`, sem ancestralidade com os commits de
`develop`. O Git passa a achar que as branches divergiram, e o próximo PR
`develop → main` traz de volta tudo que já foi mergeado, com conflitos. Depois
de dois ou três ciclos, a situação vira ingovernável.

Configure em *Settings → General → Pull Requests*:

- [x] Allow squash merging — *Default to pull request title*
- [x] Allow merge commits
- [ ] Allow rebase merging
- [x] Automatically delete head branches

---

## 21. Estratégia de QA

QA é **onde se decide se algo pode ir para produção**. Precisa de três
propriedades:

1. **Dados próprios** — branch `qa` separada no Neon e `volta_qa` no Atlas.
2. **Configuração equivalente à de produção** — mesma imagem, mesmas variáveis
   com valores diferentes, mesmo health check.
3. **Ser descartável** — deve dar para apagar e recriar o banco de QA a partir
   dos scripts do repositório Database sem pedir autorização a ninguém.

### Automático

```text
merge em develop → build + testes → imagem (sha-* + qa)
                 → deploy em volta-<app>-qa → smoke test em /health
```

### Validação humana antes do PR para `main`

- fluxo principal ponta a ponta (Mobile de debug apontando para a API de QA);
- funcionalidade nova conforme a issue;
- nada que funcionava antes quebrou;
- Chatbot respondendo com o banco de QA;
- Website: preview da Vercel da branch `develop`.

Checklist no template de PR de `develop → main`. Checklist que vive no PR é
lido; checklist em documento à parte não é.

### Mobile e QA

Gere a variante de debug apontando para a URL da API de QA (via
`buildConfigField` ou product flavors) e a de release para PROD. O APK de debug
publicado como artifact é o que o grupo instala para validar.

---

## 22. Estratégia de produção

### Portões

```text
1. CI passou no PR para develop        (bloqueante)
2. Validado em QA                      (checklist)
3. PR develop → main aprovado por CODEOWNER
4. CI rodou de novo no merge           (bloqueante)
5. Imagem publicada (sha-* + latest)
6. ⏸ Aprovação manual no Environment prod
7. Deploy + smoke test
```

Sete portões, dois com ação humana (3 e 6). O resto é automático. Essa é a
diferença entre processo pesado e processo bem colocado.

### Rollback

**1. Painel do Render (segundos).** Volta para um dos dois deploys anteriores.

**2. Redeploy de uma tag `sha-*` anterior (1–2 minutos).** É para isso que as
tags imutáveis existem: dispare o `cd.yml` via `workflow_dispatch` informando a
tag antiga. Sem rebuild, sem PR, sem esperar CI.

**3. `git revert` do merge commit em `main`** → PR → pipeline normal. Os dois
primeiros estancam o sangramento; este resolve.

Para o Website, a Vercel promove um deployment anterior pelo painel.

**Regra decorrente:** a limpeza do GHCR nunca pode apagar as tags `sha-*`
recentes.

### Runbook

`DevOps/docs/04-runbook-deploy.md`, em uma página: como disparar deploy manual,
como fazer rollback, onde ficam os logs, quem aprova produção e o que fazer se o
health check falhar. Escreva **antes** de precisar.

---

## 23. Comparação das alternativas arquiteturais

### 23.1 Multi-repo vs monorepo

| | **Multi-repo** (escolhido) | Monorepo |
|---|---|---|
| Isolamento de CI | Natural | Exige filtros de caminho |
| Visibilidade de contribuição individual | **Alta** | Diluída |
| Mudança que cruza componentes | Vários PRs | Um PR |
| Duplicação de configuração | Alta (mitigada por reusable workflows) | Baixa |

Casa com a divisão por disciplina e deixa a atribuição individual evidente, que
é critério de avaliação.

### 23.2 Visibilidade dos repositórios

| | **Públicos** (escolhido) | Privados no Free |
|---|---|---|
| Proteção de branch / ruleset | ✅ | ❌ |
| Environments com aprovação | ✅ | ❌ |
| CODEOWNERS | ✅ | ❌ |
| Minutos de Actions | Ilimitados | 2.000/mês na org |
| Código fechado | ❌ | ✅ |

Decisão do professor de DevOps, que avalia code review e PR com proteção da
`main`. Em repositório privado no plano Free esses recursos simplesmente não
existem — a abertura é o que torna o requisito cumprível.

### 23.3 Onde ficam os workflows

| Abordagem | Prós | Contras | Uso aqui |
|---|---|---|---|
| Duplicar em cada repo | Autonomia total | Corrigir bug = 5 PRs | CI de linguagem |
| **Reusable no DevOps** | Uma fonte, versionável | Acoplamento entre repos | Docker e deploy |
| Composite action | Reuso fino de steps | Sem `permissions`/`environment` próprios | Não agora |
| Starter workflow | Sem acoplamento | Cópias divergem | Bootstrap apenas |

### 23.4 Registry

| | **GHCR** (escolhido) | Docker Hub |
|---|---|---|
| Autenticação no CI | `GITHUB_TOKEN`, zero config | Secret com credencial |
| Rate limit de pull | Sem limite relevante | Limitado no gratuito |
| Integração com o repo | Nativa | Externa |

### 23.5 Hospedagem do Website

| | **Vercel** (escolhido) | Render Static Site | Container nginx |
|---|---|---|---|
| Custo | Grátis (Hobby) | Grátis | Consome horas do Render |
| Preview por PR | ✅ nativo | Parcial | Não |
| Cold start | Não tem | Não tem | ~1 min |
| Peças a manter | Nenhuma | Nenhuma | Dockerfile + nginx.conf |

### 23.6 Banco Postgres

| | Render Free | **Neon Free** (escolhido) | Aiven Free |
|---|---|---|---|
| Expira | **30 dias** | Não | Não |
| Instâncias gratuitas | 1 por workspace | Vários projetos | 1 por conta |
| Branching de banco | Não | **Sim** | Não |
| Hiberna por inatividade | Não | Sim (scale-to-zero) | Sim |
| Serve QA + PROD sem gambiarra | Não | **Sim**, via branches | Exigiria 2 contas ou 2 bancos lógicos |

Critério decisivo: o branching do Neon dá QA e PROD isolados dentro do mesmo
projeto gratuito, sem precisar administrar duas contas nem abrir mão de
isolamento entre ambientes — o problema que o Aiven exigiria resolver na mão.

### 23.7 Gatilho de deploy

| | **Deploy hook** (escolhido) | Render API | Auto-deploy |
|---|---|---|---|
| Configuração | 1 secret | API key + service ID | Nenhuma |
| Fixa tag imutável | ✅ via `imgURL` | ✅ | — |
| Existe para image-backed | Sim | Sim | **Não** |

### 23.8 Modelo de branching

| | Git Flow completo | **Simplificado** (escolhido) | Trunk-based |
|---|---|---|---|
| Branches permanentes | main, develop, release | main, develop | main |
| Ambientes | 3+ | 2 | 1–2 |
| Adequado a equipe pequena | Não | Sim | Sim, com feature flags |

Trunk-based exigiria feature flags e disciplina de testes que o projeto ainda
não tem. Duas branches mapeiam diretamente nos dois ambientes, o que torna a
arquitetura fácil de explicar numa arguição.

---

## 24. Evolução futura para Kubernetes

Kubernetes **não** entra agora: não há requisito de escala, alta disponibilidade
ou múltiplos nós, e a operação custaria mais tempo do que a aplicação inteira.

O que **não** mudaria numa eventual migração — e é por isso que esta arquitetura
é uma boa base:

- os Dockerfiles;
- as imagens no GHCR e a estratégia de tags imutáveis;
- os workflows de CI e de build/push;
- a separação QA/PROD e a gestão de secrets.

O que mudaria: apenas o **último passo**.

```text
hoje:    build → GHCR → deploy hook (Render)
depois:  build → GHCR → kubectl set image / Helm upgrade / commit GitOps
```

Caminho mínimo:

1. `Deployment` + `Service` + `Ingress` para API e Chatbot, referenciando
   `ghcr.io/app-volta/api:sha-*`.
2. Um namespace por ambiente (`volta-qa`, `volta-prod`).
3. Como as imagens são públicas, nem o `Secret` do tipo `dockerconfigjson` é
   necessário.
4. Argo CD ou Flux para GitOps — aí o DevOps vira a fonte de verdade do estado
   desejado, continuação natural da centralização que já existe.

---

## 25. Recomendações finais

**Sequência de implantação.** (1) DevOps com os reusable workflows; (2) CI da
API; (3) CD da API + Dockerfile; (4) Compose; (5) Chatbot; (6) Website +
Vercel; (7) Mobile e Database. A API serve de piloto — os erros aparecem uma
vez, não cinco.

**Ligue o ruleset depois que o CI rodar verde uma vez.** Ligar antes bloqueia
todo mundo, e a primeira reação da equipe é pedir para desligar. Copie o nome
exato do check da interface.

**Exclua o `volta-landing-*` do ruleset** antes que o 1º ano trave num merge que
eles não têm requisito de fazer via PR.

**Padronize os nomes dos jobs.** `build-test` e `validate-pr` em todos os
repositórios — é o que permite um único ruleset de organização.

**Crie a tag `v1` no DevOps** antes de referenciar os reusable workflows nos
outros repositórios, senão o `@v1` não resolve.

**`concurrency` em tudo.** `cancel-in-progress: true` no CI, `false` no deploy.

**Health check é infraestrutura, não enfeite.** Sem `/actuator/health` e
`/health` não há smoke test, não há verificação de deploy e o Render não sabe se
o serviço subiu.

**Revise o que entra na imagem pública.** Rode `docker run --rm -it
ghcr.io/app-volta/api:latest sh` uma vez e confira o que está lá dentro.

**Um `.env.example` completo em cada repositório.** É a documentação que as
pessoas realmente leem.

**Não coloque uptime pinger nos serviços do Render.** Queima a cota de horas
gratuitas da organização inteira.

**Documente a decisão, não só a configuração.** Numa arguição individual,
explicar por que o deploy fixa a tag `sha-*` em vez de usar `latest` vale muito
mais do que recitar o YAML.

---

*Documento mantido pelo time de DevOps · Projeto Volta*