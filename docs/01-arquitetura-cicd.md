# Arquitetura de CI/CD — Projeto Volta

> Repositório: `app-volta/DevOps` · Caminho: `docs/01-arquitetura-cicd.md`
> Versão 4 — revisada após a migração do Render para Kubernetes (k3s em EC2 do AWS Academy Learner Lab).

---

## Decisões fechadas

| Decisão | Consequência |
|---|---|
| **Todos os repositórios públicos** | Proteção de branch, rulesets, Environments e CODEOWNERS disponíveis; minutos de Actions ilimitados |
| **Ruleset no nível da organização**, mínimo 1 aprovação | Uma configuração vale para todos os repositórios, com exclusão do `volta-landing-page` |
| **Imagens no GHCR públicas** | Storage gratuito; cluster e Compose sem credencial de registry |
| **API e Chatbot em k3s** (EC2 t3.medium), **Website na Vercel** | Kubernetes é requisito da disciplina; o front não consome crédito AWS |
| **Postgres no Neon**, MongoDB no Atlas | Bancos gerenciados fora do cluster, com branching por ambiente |
| **Deploy por SSH + `kubectl apply -k`** | O Learner Lab não permite criar roles IAM, o que inviabiliza OIDC |

Requisito acadêmico registrado: o professor de DevOps avalia o uso de **code
review e Pull Request** com proteção da `main`, e exige **Kubernetes** como
orquestrador em nuvem. Isso eleva a proteção de branch
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
17. [Deploy: Kubernetes e Vercel](#17-deploy-kubernetes-e-vercel)
18. [Estrutura de diretórios do DevOps](#18-estrutura-de-diretórios-do-devops)
19. [Fluxo completo em diagrama](#19-fluxo-completo-em-diagrama)
20. [Regras de merge](#20-regras-de-merge)
21. [Estratégia de QA](#21-estratégia-de-qa)
22. [Estratégia de produção](#22-estratégia-de-produção)
23. [Comparação das alternativas arquiteturais](#23-comparação-das-alternativas-arquiteturais)
24. [Histórico da migração Render → Kubernetes](#24-histórico-da-migração-render--kubernetes)
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
│  Reusable workflows · Compose · Scripts · Manifestos k8s · Docs      │
└──────────────────────────────────────────────────────────────────────┘
                                │  publica / aciona
                                ▼
┌──────────────────────────────────────────────────────────────────────┐
│ PLANO 3 — EXECUÇÃO                                                   │
│  GHCR (imagens públicas) · k3s/EC2 (API, Chatbot) · Vercel (Website) │
│  Neon (PostgreSQL) · MongoDB Atlas                                   │
└──────────────────────────────────────────────────────────────────────┘
```

Fluxo do artefato:

```text
Código → CI (build + teste) → Imagem Docker → GHCR → repository_dispatch
                                                        │
                                              DevOps: kustomize edit set image
                                                        │
                                              SSH → kubectl apply -k → k3s

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

O Website é um bundle estático. Conteinerizá-lo significaria disputar memória
com a API e o Chatbot no nó único e manter um `nginx.conf` — sem ganho.
A Vercel entrega deploy automático, CDN e **preview por Pull Request**, que é
genuinamente útil para revisar mudança de front-end.

O Dockerfile continua existindo no repositório para o Compose local e para
demonstrar conteinerização, mas não é o caminho de produção.

### 2.4 O banco não fica no cluster

Rodar Postgres dentro do k3s significaria disputar os 4 GB da t3.medium com as
aplicações e assumir a responsabilidade por volume, backup e restore — trabalho
de operação que não agrega nada ao que a disciplina avalia.

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

**Redis** (ranking de cooperativas) e **Neo4j** seguem com hospedagem a
definir — a decisão é a mesma em espírito: serviço gerenciado fora do nó.

Único ponto de atenção: como o Neon do plano gratuito também aplica
**scale-to-zero** — a instância de computação hiberna depois de alguns minutos
sem uso —, o primeiro acesso após um período parado tem uma latência maior
(volta em segundos, não minutos, mas é perceptível). Vale religar antes de uma
demonstração, pelo mesmo motivo da EC2.

Para o Chatbot, **MongoDB Atlas M0**
(gratuito, 512 MB), com dois bancos lógicos — `volta_qa` e `volta_prod`.

### 2.5 Imagens do GHCR públicas

Storage gratuito, k3s puxando imagem sem `imagePullSecret` e Compose
funcionando sem login. O preço é que **tudo dentro da imagem é público** — o que transforma
várias recomendações da seção 13 em requisitos.

---

## 3. Responsabilidade de cada repositório

| Repositório | Produz | CI | CD |
|---|---|---|---|
| **API** | `ghcr.io/app-volta/api` | Maven build + testes | k3s QA (auto) / PROD (com aprovação) |
| **API Redis** | `ghcr.io/app-volta/api-redis` | Maven build + testes | k3s QA (auto) / PROD (com aprovação) |
| **Mobile** | APK como artifact | Gradle build + testes + lint | — |
| **Chatbot** | `ghcr.io/app-volta/chatbot` | Ruff + pytest | k3s QA (auto) / PROD (com aprovação) |
| **Website** | Bundle estático | Lint + tsc + build | Vercel: preview (develop) / produção (main) |
| **Database** | Scripts SQL + `.drawdb` | Execução em Postgres efêmero | — |
| **DevOps** | Reusable workflows, manifestos k8s, Compose, docs | Lint de YAML | Aplica os manifestos via SSH |
| **volta-landing-page** | Página do 1º ano | — | Fora do ruleset e desta arquitetura |

Detalhamentos que importam:

**API.** Expõe `/actuator/health` — não é enfeite: é o alvo da readiness probe
do Kubernetes e do smoke test pós-deploy. A porta vem de variável de ambiente
(`SERVER_PORT`), o que mantém o container portátil entre Compose e cluster.

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
develop  ──►  Environment "qa"    ──►  namespace volta-qa    ──►  Neon branch qa / volta_qa
                                       Vercel: preview da branch develop

main     ──►  Environment "prod"  ──►  namespace volta-prod  ──►  Neon branch prod / volta_prod
                                       Vercel: produção

Um único cluster k3s, dois namespaces. O isolamento é lógico: Secrets,
ConfigMaps, Services e ResourceQuota independentes por namespace.
```

### Por que GitHub Environments

Com repositórios públicos, os Environments resolvem três problemas sem
ferramenta extra:

1. **Secrets por ambiente.** `SSH_PRIVATE_KEY` e o host do cluster existem com
   o mesmo nome nos dois ambientes. O workflow é um só; o valor muda conforme o
   `environment:` declarado no job.
2. **Aprovação manual antes de produção.** No environment `prod`, marque
   *Required reviewers*. O deploy fica parado esperando um clique, mesmo com o
   merge em `main` já feito. É o portão de produção.
3. **Restrição de branch.** `prod` só aceita deploy a partir de `main`; `qa` só
   a partir de `develop`. Mesmo que alguém dispare o workflow manualmente da
   branch errada, o GitHub recusa.

Bônus: a aba *Deployments* do repositório passa a mostrar o histórico de
implantações com commit, autor e horário — documentação automática do que subiu
e quando.

### Nomenclatura

```text
namespace volta-qa      Services: api, api-redis, chatbot
namespace volta-prod    Services: api, api-redis, chatbot
```

O nome do Service é igual nos dois namespaces — quem diferencia é o namespace,
não o nome. Isso mantém os manifestos `base/` idênticos e joga toda a variação
para os overlays.

### Orçamento da EC2

A t3.medium é cobrada por hora ligada. O EBS de 30 GB (~US$ 2,40/mês) e o
Elastic IP (~US$ 3,60/mês) são cobrados mesmo com a instância parada.

| Cenário | Custo estimado/mês | Cabe nos US$ 50? |
|---|---|---|
| Ligada ~2 h/dia | ~US$ 10 | Sim, com folga |
| Ligada ~8 h/dia | ~US$ 17 | Sim |
| Ligada 24/7 | ~US$ 37 | Consome o crédito em ~5 semanas |

Três regras:

- **A instância sobe sob demanda**, por workflow manual (`workflow_dispatch`), e
  para sozinha após ~15 minutos sem tráfego de rede, via alarme do CloudWatch.
- **QA fica com `replicas: 0` por padrão.** Sobe quando alguém vai validar.
- **Na apresentação, suba a instância 10 minutos antes.** k3s leva ~1 minuto
  para ficar pronto e os pods mais um pouco. O mesmo vale para o Neon, cuja
  instância de computação também entra em scale-to-zero por inatividade.

### Restrições do AWS Academy Learner Lab

Não é uma conta AWS comum, e as restrições moldaram a arquitetura:

| Restrição | Consequência |
|---|---|
| Sem permissão para criar roles/usuários IAM | **OIDC no Actions é inviável** → deploy por SSH |
| Sem Identity Providers | idem |
| Tipos de EC2 limitados até `large` | t3.medium é o teto prático de custo/benefício |
| Regiões `us-east-1` / `us-west-2` | Latência maior, aceita |
| Credenciais de sessão expiram em 4 h | Nada de credencial AWS em secret do GitHub; a EC2 usa IMDS |
| Instância reinicia com IP público novo | **Elastic IP é obrigatório** |
| `LabRole` e `LabInstanceProfile` já existem | Reaproveitados para o acesso ao S3 e ao CloudWatch |

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
| Deploy no k3s | **Reusable no DevOps** | Idêntico para os dois serviços |
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
├── reusable-validate-pr.yaml         (workflow_call)
├── reusable-docker-build-push.yaml   (workflow_call)
├── reusable-k3s-deploy.yaml          (workflow_call)
├── dispatch-deploy.yaml              (repository_dispatch + workflow_dispatch)
├── ec2-power.yaml                    (workflow_dispatch)
├── ci.yaml                           (lint de YAML e do Compose)
└── ghcr-cleanup.yaml                 (schedule mensal + workflow_dispatch)
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

### 11.2 `reusable-docker-build-push.yaml`

```yaml
inputs:   image-name, environment, context, dockerfile, push,
          notify-devops, devops-repository
secrets:  devops-dispatch-token
outputs:  image, image-tag        # ghcr.io/app-volta/api, qa-a1b2c3d
```

Valida o `environment` (só aceita `qa` ou `prod`), faz login no GHCR com
`GITHUB_TOKEN`, build para `linux/amd64`, cache de camadas via `type=gha`, tags
da seção 16, labels OCI e push condicional.

Quando `notify-devops` está ligado, o último passo dispara `repository_dispatch`
para o repositório DevOps:

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

O `GITHUB_TOKEN` do repositório de origem **não** consegue disparar dispatch
cross-repo. É preciso um PAT com escrita no DevOps, no secret
`devops-dispatch-token`; o workflow falha explicitamente se ele estiver
ausente.

### 11.3 `reusable-k3s-deploy.yaml`

Substitui o antigo `reusable-render-deploy.yml`, removido junto com o Render.

```yaml
inputs:   environment, service, image, image-tag, health-url, rollout-timeout
secrets:  ssh-private-key, ssh-host
```

Responsabilidades previstas:

1. `kustomize edit set image <service>=<image>:<tag>` no overlay do ambiente;
2. commit e push do overlay no próprio DevOps (o Git vira o histórico do que
   está implantado);
3. SSH na EC2 e `kubectl apply -k kubernetes/overlays/<env>`;
4. `kubectl rollout status` e smoke test no health check;
5. resumo da implantação no `GITHUB_STEP_SUMMARY`.

Declara `environment: ${{ inputs.environment }}` — é esse job que fica parado
esperando a aprovação em produção. Em ordem:

1. `kustomize edit set image` no overlay do ambiente;
2. commit e push do overlay no próprio DevOps (o Git vira o histórico do que
   está implantado);
3. `scp` da pasta `kubernetes/` para a instância — o runner já tem o commit
   exato em mãos, o que evita a instância ficar dessincronizada;
4. `kubectl apply -k kubernetes/overlays/<env>`;
5. `kubectl rollout status` — só retorna sucesso quando a readiness probe passa,
   e é essa a verificação real de que a aplicação subiu;
6. smoke test opcional pelo ingress, que valida o caminho completo (Traefik →
   Service → pod) que o `rollout status` sozinho não cobre.

Quando o Deployment está com `replicas: 0` (o padrão em QA), os passos 5 e 6 são
pulados com um aviso: a imagem fica registrada no manifesto e sobe quando
alguém escalar.

### 11.3.1 `dispatch-deploy.yaml`

Ponto de entrada do deploy, com dois gatilhos:

- **`repository_dispatch`** (tipo `deploy`) — automático, disparado pelos
  repositórios de aplicação logo após publicarem a imagem;
- **`workflow_dispatch`** — manual, para reimplantar uma tag antiga sem rebuild.
  É o caminho de rollback pela interface.

O payload do dispatch vem de fora deste repositório, então nada nele é usado sem
validação: serviço e ambiente conferidos contra uma lista fechada, tag conferida
contra o padrão `<env>-<sha7>`, e — o check que mais importa — **o prefixo da
tag precisa bater com o ambiente alvo**, o que impede implantar uma imagem de QA
em produção.

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
| `SSH_PRIVATE_KEY` | **Secret de repositório** | GitHub (DevOps) |
| `SSH_HOST` (Elastic IP) | Variable de repositório | GitHub (DevOps) |
| `DEVOPS_DISPATCH_TOKEN` (PAT) | Secret de repositório | GitHub (repos de app) |
| `GHCR_CLEANUP_TOKEN` (PAT) | Secret de repositório | GitHub (DevOps) |
| Senha do Postgres (Neon) | Secret | `Secret` do namespace no k3s |
| String de conexão MongoDB Atlas | Secret | `Secret` do namespace no k3s |
| `JWT_SECRET` | Secret | `Secret` do namespace (**diferente por namespace**) |
| Chave de API da LLM | Secret | `Secret` do namespace no k3s |
| Credenciais AWS (S3) | Temporárias | IMDS da EC2 via `LabInstanceProfile` |
| `GITHUB_TOKEN` | Automático | Gerado pelo Actions a cada execução |
| URL pública da API por ambiente | Variable | `vars` do Environment |
| `VITE_API_BASE_URL` | Variable (**nunca secret**) | Painel da Vercel, por ambiente |
| Versões de Java/Node/Python | Versionado no Git | Dentro do workflow |
| Dockerfiles, Compose, manifestos k8s | Versionado no Git | Repositório |
| `.env.example` (chaves sem valores) | Versionado no Git | Repositório |
| `.env` (com valores) | **Nunca versionado** | Máquina local |

### Onde o secret realmente mora

**Os secrets da aplicação não ficam no GitHub.** Senha de banco, chave de LLM e
`JWT_SECRET` viram `Secret` do Kubernetes, criados manualmente uma vez por
namespace, porque quem precisa deles é o container em execução — não o
pipeline. O GitHub guarda apenas o que o *pipeline* precisa: a chave SSH e os
PATs.

Credencial AWS é um caso à parte e merece a ênfase: **nenhuma vai para secret do
GitHub**. As do Learner Lab expiram em 4 horas, o que tornaria a rotação um
trabalho manual semanal. A EC2 obtém credenciais pelo IMDS através do
`LabInstanceProfile`, e elas se renovam sozinhas.

Um `JWT_SECRET` diferente entre QA e PROD não é preciosismo: garante que um
token emitido em QA não seja aceito em produção.

---

## 14. Estratégia de Docker

### Princípios

- **Multi-stage sempre**: o compilador não vai para produção.
- **`linux/amd64` obrigatório** — arquitetura da EC2 t3.medium. Quem desenvolve
  em Mac com Apple Silicon gera `arm64` por padrão e o pod entra em
  `CrashLoopBackOff` com `exec format error`.
- **Usuário não-root** no estágio final.
- **Porta por variável de ambiente**: definida no ConfigMap do overlay e
  espelhada no `containerPort` do Deployment.
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
| Proxy reverso | **Não** | Traefik (no cluster) e Vercel já resolvem TLS e roteamento |

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
| `qa-a1b2c3d` | **Imutável** | A verdade em QA. Todo deploy de QA fixa uma dessas |
| `prod-a1b2c3d` | **Imutável** | A verdade em PROD |
| `qa` | Móvel | Aponta para o que está em QA |
| `prod` | Móvel | Aponta para o que está em PROD |

O prefixo do ambiente na tag imutável é deliberado: olhando o `image:` de um
Deployment dá para saber, sem consultar nada, de qual esteira aquele artefato
veio. O deploy **sempre** referencia a tag imutável; as móveis são conveniência
para humanos e para o Compose. É isso que torna o rollback trivial e o histórico
auditável.

Semantic versioning fica de fora: não há processo de release, e versão que
ninguém incrementa com critério é pior que não ter versão.

### Quando construir e quando publicar

| Evento | Build? | Push? |
|---|---|---|
| PR para `develop`/`main` | Não | Não |
| Merge em `develop` | Sim | `qa-<sha>` + `qa` |
| Merge em `main` | Sim | `prod-<sha>` + `prod` |

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

Se esquecer o passo 2, o pod fica em `ImagePullBackOff` — o k3s não tem
credencial de registry configurada, por decisão.

### Limpeza

Workflow mensal: apaga versões sem tag e mantém as ~10 tags imutáveis mais
recentes.

Cuidado crítico: o k3s guarda a imagem no cache do containerd do nó, mas o
`imagePullPolicy` e qualquer recriação de pod em um nó limpo voltam ao registry.
Apagar uma tag em uso **derruba o serviço no próximo restart**. Nunca apague
`qa` nem `prod`, e mantenha as tags `<env>-<sha>` recentes, que são o alvo de
rollback.

---

## 17. Deploy: Kubernetes e Vercel

### 17.1 API e Chatbot — k3s em EC2

**Por que k3s e não EKS.** O control plane do EKS custa ~US$ 73/mês — 146% do
crédito do Learner Lab antes de subir um único pod. O k3s é Kubernetes
certificado pela CNCF: mesma API, mesmo `kubectl`, mesmos manifestos. O que se
perde é alta disponibilidade do control plane, que não é requisito aqui.

| | EKS | **k3s em EC2** (escolhido) | Render (anterior) |
|---|---|---|---|
| Requisito "Kubernetes" atendido | Sim | **Sim** | Não |
| Custo do control plane | ~US$ 73/mês | **US$ 0** | — |
| Cabe no Learner Lab | Não | **Sim** | — |
| Alta disponibilidade | Sim | Não (nó único) | Parcial |

**Topologia.**

```text
EC2 t3.medium (Amazon Linux 2023) + Elastic IP
└── k3s (single-node, Traefik embutido)
    ├── namespace volta-qa     → api, api-redis, chatbot   (replicas: 0 por padrão)
    └── namespace volta-prod   → api, api-redis, chatbot
```

Sem ELB e sem NAT Gateway — os dois maiores sorvedouros de crédito numa conta
AWS pequena. O Traefik que já vem no k3s faz o papel de ingress.

**Ingress e DNS.** `sslip.io` resolve qualquer IP embutido no próprio nome, o
que dispensa comprar domínio e habilita HTTPS via cert-manager:

```text
api.qa.<EIP>.sslip.io    → Service api,      namespace volta-qa,   port 8080
api.<EIP>.sslip.io       → Service api,       namespace volta-prod, port 8080
ranking.qa.<EIP>.sslip.io → Service api-redis, namespace volta-qa,   port 8081
ranking.<EIP>.sslip.io    → Service api-redis, namespace volta-prod, port 8081
chat.qa.<EIP>.sslip.io   → Service chatbot,  namespace volta-qa,   port 8000
chat.<EIP>.sslip.io      → Service chatbot,  namespace volta-prod, port 8000
```

**Kustomize.** `base/` descreve o que é igual nos dois ambientes; os overlays
descrevem só a diferença.

```text
kubernetes/
├── namespace.yaml            # volta-qa, volta-prod
├── base/
│   ├── api/{deployment,service,kustomization}.yaml
│   ├── api-redis/{deployment,service,kustomization}.yaml
│   ├── chatbot/{deployment,service,kustomization}.yaml
│   └── ingress.yaml
└── overlays/
    ├── qa/{kustomization,configmap,replicas-patch}.yaml
    └── prod/{kustomization,configmap,resources-patch}.yaml
```

O deploy roda `kustomize edit set image` no overlay, commita e aplica. O estado
desejado fica versionado no Git — é GitOps sem Argo CD.

**Autenticação do deploy: SSH.** O Learner Lab não permite criar roles IAM, o
que elimina OIDC e SSM. Sobra chave SSH: pública no `authorized_keys` da
instância, privada no secret `SSH_PRIVATE_KEY` do DevOps.

**Health checks.** `readinessProbe` em `/actuator/health` (API) e `/health`
(Chatbot); `livenessProbe` com `initialDelaySeconds: 30` e `timeoutSeconds: 5`.
Sem probe, o `kubectl rollout status` retorna sucesso antes da aplicação estar
de pé e o deploy fica verde com o serviço quebrado.

**Secrets no cluster.** Criados manualmente com `kubectl create secret`, uma vez
por namespace. Sem Sealed Secrets: a complexidade não se paga no escopo
acadêmico, e a alternativa — commitar segredo cifrado — exigiria gestão de
chave que ninguém vai manter.

**Fotos do mobile.** Não passam pelo cluster. A API assina uma presigned URL do
S3 (expiração de 15 min, Content-Type restrito), o mobile envia direto para o
bucket e a API só registra a referência no banco. Com 512 MB de heap, a
alternativa — upload atravessando o Spring Boot — não sobreviveria a dois
usuários simultâneos. As credenciais AWS vêm do IMDS da instância via
`LabInstanceProfile`, nunca de secret do GitHub.

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
│   │   ├── reusable-validate-pr.yaml
│   │   ├── reusable-docker-build-push.yaml
│   │   ├── reusable-k3s-deploy.yaml      # deploy no cluster
│   │   ├── dispatch-deploy.yaml          # recebe o repository_dispatch
│   │   ├── ec2-power.yaml                # sobe/para a instância sob demanda
│   │   ├── ci.yaml
│   │   └── ghcr-cleanup.yaml
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
├── kubernetes/
│   ├── namespace.yaml
│   ├── base/
│   │   ├── api/
│   │   ├── api-redis/
│   │   ├── chatbot/
│   │   └── ingress.yaml
│   └── overlays/
│       ├── qa/
│       └── prod/
├── vercel/
│   └── configuracao-website.md
├── scripts/
│   ├── setup-local.sh
│   ├── lib-aws.sh               # convenções compartilhadas
│   ├── provision-ec2-k3s.sh     # provisionamento idempotente (roda local)
│   ├── cloud-init-k3s.sh        # user data: instala o k3s
│   ├── rollback.sh              # rollback de emergência
│   └── check-health.sh
│
├── docs/
│   ├── 01-arquitetura-cicd.md   ← este documento
│   ├── 02-ambientes.md
│   ├── 03-secrets.md
│   ├── 04-runbook-deploy.md
│   ├── 05-padroes-git.md
│   └── 06-cluster-k3s.md
│
└── README.md
```

### Modificações em relação à estrutura original

| Mudança | Motivo |
|---|---|
| `workflows/` → `.github/workflows/` | Requisito técnico do `workflow_call` |
| `docker-compose/` → `compose/` | Evita `docker-compose/docker-compose.yml` |
| `kubernetes/` reintroduzido | Kubernetes virou requisito; manifestos Kustomize versionados aqui |
| `render/` removido | Render descontinuado em favor do k3s |
| `docker/` vira pasta de templates | Dockerfile de produção mora junto do código que ele constrói |
| `vercel/` adicionado | O Website não roda no cluster; a configuração precisa estar versionada |

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
   build-test  ──►  docker-build-push  ──►  repository_dispatch ──► DevOps
                    ┌──────────────────────┐    ┌───────────────────────────┐
                    │ login GHCR           │    │ kustomize edit set image  │
                    │ build amd64          │    │ commit no DevOps          │
                    │ tags: qa-a1b2c3d, qa │    │ ssh: kubectl apply -k qa  │
                    │ push                 │    │ rollout status + /health  │
                    └──────────────────────┘    └─────────────┬─────────────┘
                                                              ▼
                                          k3s: namespace volta-qa
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
                    (tags: prod-a1b2c3d,    (Environment prod:
                           prod)             required reviewers)
                                                    │
                                                    ▼
                                    ssh: kubectl apply -k prod + smoke test
                                                    │
                                                    ▼
                                        k3s: namespace volta-prod
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
  DevOps             → CI de YAML + limpeza mensal do GHCR + recebe o dispatch.
  EC2/k3s            → start manual (workflow_dispatch); auto-stop por
                       inatividade (~15 min, alarme do CloudWatch).
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
5. Imagem publicada (prod-<sha> + prod)
6. ⏸ Aprovação manual no Environment prod
7. Deploy + smoke test
```

Sete portões, dois com ação humana (3 e 6). O resto é automático. Essa é a
diferença entre processo pesado e processo bem colocado.

### Rollback

**1. `kubectl rollout undo` (segundos).** Volta o Deployment para a revisão
anterior direto no cluster. É o estanca-sangramento — mas deixa o cluster
divergente do Git, então precisa ser seguido de 2 ou 3.

```bash
kubectl -n volta-prod rollout undo deployment/api
```

**2. Redeploy de uma tag `<env>-<sha>` anterior (1–2 minutos).** É para isso que
as tags imutáveis existem: dispare o workflow de deploy via `workflow_dispatch`
informando a tag antiga. Sem rebuild, sem PR, sem esperar CI. Como o overlay é
commitado, o Git volta a refletir o cluster.

**3. `git revert` do merge commit em `main`** → PR → pipeline normal. Os dois
primeiros estancam o sangramento; este resolve.

Para o Website, a Vercel promove um deployment anterior pelo painel.

**Regra decorrente:** a limpeza do GHCR nunca pode apagar as tags
`<env>-<sha>` recentes.

### Runbook

`DevOps/docs/04-runbook-deploy.md`, em uma página: como disparar deploy manual,
como fazer rollback, onde ficam os logs (`kubectl logs`, `journalctl -u k3s`),
quem aprova produção, como subir a EC2 quando estiver parada e o que fazer se o
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
| Custo | Grátis (Hobby) | Grátis | Consome memória do nó k3s |
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

| | **repository_dispatch + SSH** (escolhido) | OIDC + SSM | GitOps (Argo CD) |
|---|---|---|---|
| Configuração | PAT + chave SSH | Role IAM + agente | Controlador no cluster |
| Fixa tag imutável | ✅ via kustomize | ✅ | ✅ |
| Viável no Learner Lab | **Sim** | **Não** (sem IAM) | Sim, mas pesa no nó |
| Estado versionado no Git | Sim (commit do overlay) | Não | Sim |

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

## 24. Histórico da migração Render → Kubernetes

A versão 3 deste documento registrava Kubernetes como *evolução futura*, com o
argumento de que não havia requisito de escala nem de alta disponibilidade. O
argumento continua correto — o que mudou foi outra coisa: **Kubernetes virou
requisito explícito da disciplina de DevOps**, junto com a exigência de nuvem
como infraestrutura. Deixou de ser uma escolha técnica de escala e passou a ser
entregável avaliado.

O que a migração **não** exigiu mudar — e é a prova de que a arquitetura
anterior era uma base sólida:

- os Dockerfiles;
- as imagens no GHCR e a estratégia de tags imutáveis;
- os workflows de CI e de validação de PR;
- a separação QA/PROD, os Environments e a gestão de secrets;
- o ruleset, o CODEOWNERS e o fluxo de branches.

O que mudou foi o **último passo** da esteira, exatamente como previsto:

```text
antes:  build → GHCR → deploy hook (Render)
agora:  build → GHCR → repository_dispatch → kustomize → SSH → kubectl apply
```

Mudanças concretas registradas:

| Item | Antes (v3) | Agora (v4) |
|---|---|---|
| Runtime | Render (image-backed) | k3s em EC2 t3.medium |
| Gatilho de deploy | Deploy hook com `imgURL` | `repository_dispatch` + SSH |
| Tag imutável | `sha-a1b2c3d` | `<env>-a1b2c3d` |
| Isolamento de ambiente | 2 serviços por app | 2 namespaces |
| `reusable-render-deploy.yml` | Existia | **Removido** |
| Manifestos | — | `kubernetes/` com Kustomize |

### O que ficou de fora, e por quê

- **Argo CD / Flux.** O controlador consumiria memória do nó único que é
  justamente o recurso escasso. O commit do overlay já dá o histórico
  auditável, que era o principal ganho do GitOps aqui.
- **Sealed Secrets.** `kubectl create secret` manual, uma vez por namespace.
- **Cluster multi-nó.** Alta disponibilidade custaria cerca de 4x o orçamento
  sem agregar ao que é avaliado. Nó único é ponto único de falha — decisão
  consciente, registrada.
- **EKS.** ~US$ 73/mês só de control plane, 146% do crédito disponível.

---

## 25. Recomendações finais

**Sequência de implantação.** (1) DevOps com os reusable workflows; (2) CI da
API; (3) build/push da API + Dockerfile; (4) Compose; (5) EC2 + k3s + Elastic
IP; (6) manifestos e deploy da API; (7) Chatbot; (8) Website + Vercel; (9)
Mobile e Database. A API serve de piloto — os erros aparecem uma
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
`/health` não há readiness probe, não há smoke test e o `kubectl rollout status`
declara sucesso antes de a aplicação estar de pé.

**Revise o que entra na imagem pública.** Rode `docker run --rm -it
ghcr.io/app-volta/api:prod sh` uma vez e confira o que está lá dentro.

**Um `.env.example` completo em cada repositório.** É a documentação que as
pessoas realmente leem.

**Aloque o Elastic IP na primeira sessão do lab.** Sem ele, cada reinício da
instância troca o IP público, o que quebra o SSH do deploy e todos os hostnames
`sslip.io` do ingress de uma vez.

**Confira o AWS Budget antes de qualquer coisa.** Alertas em US$ 10, US$ 25 e
US$ 40. O vilão é instância esquecida ligada — o auto-stop por inatividade
existe justamente para isso.

**Documente a decisão, não só a configuração.** Numa arguição individual,
explicar por que o deploy fixa a tag `<env>-<sha>` em vez de usar a tag móvel —
ou por que k3s em vez de EKS — vale muito mais do que recitar o YAML.

---

*Documento mantido pelo time de DevOps · Projeto Volta*