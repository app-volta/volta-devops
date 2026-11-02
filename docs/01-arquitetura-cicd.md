# Arquitetura e CI/CD

Como o Volta é construído e publicado, e por que cada escolha foi feita. Os
passos do dia a dia ficam nos outros documentos:

| Preciso de... | Documento |
|---|---|
| Diferenças entre QA e produção | [`02-ambientes.md`](02-ambientes.md) |
| Onde guardar senhas e tokens | [`03-secrets.md`](03-secrets.md) |
| Fazer deploy ou rollback | [`04-runbook-deploy.md`](04-runbook-deploy.md) |
| Regras de branch, commit e PR | [`05-padroes-git.md`](05-padroes-git.md) |
| Operar o cluster | [`06-cluster-k3s.md`](06-cluster-k3s.md) |
| Configurar o Website | [`07-vercel-website.md`](07-vercel-website.md) |

## 1. Visão geral

```text
Código (um repositório por aplicação, todos públicos)
   │  CI próprio + chama os workflows reutilizáveis
   ▼
volta-devops: workflows reutilizáveis · manifestos · Compose · scripts · docs
   │  publica / aciona
   ▼
GHCR (imagens) · k3s na EC2 (api, api-redis, chatbot) · Vercel (website)
Neon (PostgreSQL) · MongoDB Atlas · Redis Cloud · Qdrant · Cloudinary · Firebase
```

```text
Código → CI (build + teste) → imagem Docker → GHCR → repository_dispatch
                                                         │
                                      kustomize edit set image
                                                         │
                                      SSH → kubectl apply -k → k3s

Website: Código → CI → Vercel (preview em develop, produção em main)
```

Princípio: **construir uma vez, implantar várias**. A imagem que passou nos
testes é a mesma que sobe em QA e em produção; nada é recompilado no destino.

### Decisões principais

| Decisão | Motivo |
|---|---|
| Repositórios públicos | Libera ruleset, Environments com aprovação e CODEOWNERS no plano gratuito. Custo: nenhum segredo pode ir para o Git |
| Imagens públicas no GHCR | Armazenamento gratuito e pull sem login. Tudo dentro da imagem é público |
| API, ranking e chatbot no k3s (EC2 t3.medium) | Kubernetes é exigido pela disciplina; EKS custaria ~US$ 73/mês só de plano de controle |
| Website na Vercel | Estático: deploy automático, CDN e preview por PR, sem gastar memória do nó |
| Bancos gerenciados fora do cluster (Neon, Atlas, Qdrant) | Não disputam os 4 GB da EC2 e não exigem backup próprio |
| Deploy por SSH + `kubectl apply -k` | O Learner Lab não cria roles IAM, então OIDC e SSM não são possíveis |

Contexto acadêmico: a disciplina de DevOps avalia code review e Pull Request com
a `main` protegida, e exige Kubernetes na nuvem.

## 2. Repositórios

| Repositório | Tecnologia | Produz / destino | CI |
|---|---|---|---|
| `volta-api-core` | Java 21, Spring Boot, PostgreSQL, JWT | `ghcr.io/app-volta/api` → k3s | Maven |
| `volta-api-redis` | Java 21, Spring Boot, Redis | `ghcr.io/app-volta/api-redis` → k3s | Maven (com Redis como service container) |
| `volta-chatbot` | Python, FastAPI, LangGraph, RAG | `ghcr.io/app-volta/chatbot` → k3s | Ruff + pytest |
| `volta-website-dad` | React, TypeScript, Vite | Vercel | lint, `tsc`, build |
| `volta-mobile` | Android (Java), Firebase | APK como artifact | Gradle |
| `volta-database` | Scripts SQL (PostgreSQL) | Nenhum | Postgres temporário |
| `volta-business-inteligence` | SQL (Data Mart no PostgreSQL) | Nenhum | Qualidade dos SQL |
| `volta-landing-page-static` | HTML e CSS | GitHub Pages | Nenhum |
| `volta-landing-page-server` | JSP, Servlet, JDBC (1º ano) | Fora desta arquitetura | Nenhum |
| `volta-docs`, `volta-database-1ano`, `.github` | Documentação, templates | n/a | n/a |
| `volta-devops` (este) | Workflows, manifestos, Compose, scripts | Aplica os manifestos por SSH | n/a |

O que cada serviço faz e como se relaciona:

- **api** (8080): CRUD, autenticação e emissão do JWT. Envia e-mail por SMTP
  (recuperação de senha).
- **api-redis** (8081): ranking de empresas (Sorted Set) e busca de cooperativas
  por proximidade (Redis GEO). O PostgreSQL da `api` continua sendo a fonte da
  verdade; o Redis guarda só índices derivados. Chama a `api` por
  `VOLTA_API_URL` repassando o JWT do usuário.
- **chatbot** (8000): agentes com RAG (Qdrant), sessões no MongoDB, métricas no
  PostgreSQL, tracing opcional no LangSmith.
- **Website e Mobile**: enviam a foto da ocorrência direto ao **Cloudinary** (sem
  chave, por upload preset) e a `api` guarda só a URL. O Mobile usa **Firebase**
  (FCM para push e Firestore).

O `JWT_KEY` é compartilhado por `api`, `api-redis` e `chatbot` dentro de cada
ambiente: a `api` emite o token e as outras o validam.

Regra para o `volta-devops`: se um arquivo precisa mudar quando o código de uma
aplicação muda, ele não é daqui.

## 3. Branches, PRs e proteção

```text
main     ──●───────────────●──────────────●──────►  PRODUÇÃO
            ╲             ╱ ╲            ╱
develop  ────●───●───●───●───●───●───●──●─────────►  QA
              ╲ ╱     ╲ ╱         ╲ ╱
feat/SCRUM-1858 ●    ●            ●
```

Branch de trabalho: `<tipo>/SCRUM-<número>`, validada por
`^(feat|fix|refactor|chore|test|docs)/SCRUM-[0-9]{1,4}$`. Fluxo completo,
commits e hotfix em [`05-padroes-git.md`](05-padroes-git.md).

| De → Para | Merge | Aprovação |
|---|---|---|
| feature → `develop` | **Squash** | 1 |
| `develop` → `main` | **Merge commit**, nunca squash | 1 + CODEOWNER |
| hotfix `fix/*` (de `main`) → `main` | Squash | 1 + CODEOWNER |
| Push direto | Bloqueado | n/a |

Squash em `develop → main` cria um commit novo sem ligação com os de `develop`;
o próximo PR traz tudo de volta com conflitos. Depois do hotfix, abra um PR de
`main` para `develop`.

### Ruleset da organização

Configurado uma vez na organização, com os mesmos nomes de check em todos os
repositórios: `build-test` e `validate-pr / validate-pr`.

| Regra | `develop` | `main` |
|---|---|---|
| PR obrigatório, 1 aprovação, conversas resolvidas | Sim | Sim |
| Checks obrigatórios | Sim | Sim |
| Descartar aprovações após novo push | Não | **Sim** |
| Exigir CODEOWNERS | Não | **Sim** |
| Branch atualizada | Não | **Sim** |
| Bloquear force push e exclusão | Sim | Sim |

- **1 aprovação, não 2**: o autor não aprova o próprio PR e com 2 pessoas a regra
  travaria tudo, levando a desligá-la na pressa.
- **Excluir `volta-landing-*`** do ruleset (padrão `volta-landing-*`): o 1º ano
  faz merge direto.
- **Sem `paths-ignore`** em workflow obrigatório: o check fica pendente para
  sempre e bloqueia o PR.
- **CODEOWNERS**: ainda não existe neste repositório (planejado). O time de
  DevOps precisa de ao menos duas pessoas, senão ninguém aprova mudança em
  workflow.
- Ligue **secret scanning** e **push protection** em todos os repositórios.

## 4. Ambientes

```text
develop ──► Environment "qa"   ──► namespace volta-qa   ──► Neon branch qa / Atlas volta_qa
main    ──► Environment "prod" ──► namespace volta-prod ──► Neon branch prod / Atlas volta_prod
```

Um único cluster k3s, dois namespaces (Secrets, ConfigMaps e Services próprios).
Tabela completa e como ligar o QA: [`02-ambientes.md`](02-ambientes.md).

**GitHub Environments** dão secrets por ambiente, restringem a branch
(`prod` só aceita `main`) e, em `prod`, exigem **aprovação manual** antes do
deploy. É o portão de produção.

### Learner Lab e orçamento

| Restrição | Consequência |
|---|---|
| Sem roles/usuários IAM | Deploy por SSH, não OIDC |
| Credenciais expiram em 4 h | Nenhuma credencial AWS vai para a aplicação; as do GitHub servem só para ligar/desligar a EC2 |
| Instância reinicia com IP novo | Elastic IP obrigatório |
| Só `us-east-1` e `us-west-2` | Usamos `us-east-1` |

A t3.medium é cobrada por hora ligada; disco (~US$ 2,40/mês) e Elastic IP
(~US$ 3,60/mês) são cobrados sempre. Ligada ~2 h/dia custa ~US$ 10/mês; 24 h
gasta o crédito de US$ 50 em ~5 semanas. Por isso a máquina liga sob demanda
(workflow manual), desliga sozinha após ~15 min sem tráfego e o QA fica com
`replicas: 0`. Em apresentações, ligue 10 minutos antes (o Neon também hiberna).

## 5. GitHub Actions

**O que muda junto, mora junto.** CI de cada linguagem (Maven, Gradle, npm, pip)
fica no repositório da aplicação; o que é igual em vários repositórios e mexe com
registro, credenciais ou plataforma de deploy é reutilizável aqui.

Convenções: `permissions: contents: read` como mínimo; `concurrency` com
`cancel-in-progress: true` no CI e `false` no deploy; jobs com os nomes
`build-test` e `validate-pr`; reutilizáveis referenciados por tag
(`@v1`), nunca pela `main`.

| Workflow (`.github/workflows/`) | Gatilho | Função |
|---|---|---|
| `reusable-validate-pr.yaml` | `workflow_call` | Valida nome da branch, destino do PR e título (Conventional Commits) |
| `reusable-docker-build-push.yaml` | `workflow_call` | Build `linux/amd64`, push no GHCR e aviso ao DevOps |
| `reusable-k3s-deploy.yaml` | `workflow_call` | Aplica a imagem no cluster e confere a saúde |
| `dispatch-deploy.yaml` | `repository_dispatch` + manual | Porta de entrada do deploy; manual serve de rollback |
| `ec2-power.yaml` | manual | Liga, desliga e mostra o estado da EC2 |
| `ghcr-cleanup.yaml` | mensal + manual | Remove versões sem tag, mantém as 10 mais recentes |

Nos repositórios de aplicação (`api`, `api-redis`, `chatbot`):

```text
ci.yaml  pull_request + push [develop, main]: validate-pr (só em PR) | build-test
cd.yaml  push [develop, main] + manual: build-test → docker → aviso ao DevOps
         ambiente pela branch: develop→qa, main→prod
```

### Build e deploy

`reusable-docker-build-push` aceita só `qa` ou `prod`, publica as tags da seção 6
e, com `notify-devops`, dispara o `repository_dispatch`:

```json
{ "event_type": "deploy",
  "client_payload": { "service": "api", "env": "qa", "image": "ghcr.io/app-volta/api",
                      "tag": "qa-a1b2c3d", "commit": "<sha>", "source_repository": "app-volta/volta-api-core" } }
```

O `GITHUB_TOKEN` não dispara workflow em outro repositório, então é preciso o PAT
`DEVOPS_DISPATCH_TOKEN`; sem ele o workflow falha de propósito.

`dispatch-deploy` valida o aviso (vem de fora): serviço e ambiente contra lista
fechada, tag no formato `<env>-<sha7>` e **prefixo da tag igual ao ambiente**
(impede subir imagem de QA em produção).

`reusable-k3s-deploy` roda, nesta ordem:

1. lê por SSH as imagens atuais dos três Deployments;
2. `kustomize edit set image` e troca do IP no overlay temporário do runner;
3. `scp` dos manifestos e `kubectl apply -k kubernetes/overlays/<ambiente>`;
4. confere que as imagens dos outros serviços não mudaram;
5. `kubectl rollout status` (só passa com a readiness verde) e smoke test no
   health check pelo ingress;
6. resumo no `GITHUB_STEP_SUMMARY`.

Com `replicas: 0` (padrão em QA), rollout e smoke test são pulados com aviso. O
workflow **não** faz commit do overlay (a `main` exige PR); tag e resultado ficam
no histórico do Actions. O job usa `environment:`, que é o que segura o deploy
de produção até a aprovação.

### CI por tipo de projeto

| Projeto | Passos |
|---|---|
| Java (api, api-redis) | `setup-java` 21 com cache Maven → `mvn -B verify` (a api-redis sobe um Redis como service container; JaCoCo exige 85% de linhas) |
| Python (chatbot) | `setup-python` 3.12 → `ruff check` → `pytest`. Nunca chama a LLM real |
| Website | `setup-node` 20 → `npm ci` → lint → `tsc --noEmit` → build (o Vite não checa tipos) |
| Mobile | `setup-java` 17 + Gradle → `assembleDebug`, testes unitários, lint → APK como artifact |
| Database | Postgres 16 temporário → scripts em ordem numérica → consultas de sanidade |

## 6. Imagens e GHCR

- **Multi-stage**, usuário não-root, `.dockerignore` sempre (com imagem pública
  ele também é controle de segurança).
- **`linux/amd64`** obrigatório: imagem `arm64` (Mac Apple Silicon) causa
  `exec format error` e `CrashLoopBackOff`.
- Java: `maven:3.9-eclipse-temurin-21` → `eclipse-temurin:21-jre-alpine`; Python:
  `python:3.12-slim`. A porta vem de variável de ambiente (ConfigMap).
- O Website tem Dockerfile só para uso local.

Nomes: `ghcr.io/app-volta/{api,api-redis,chatbot}`, sem sufixo de ambiente: a
mesma imagem serve QA e PROD.

| Tag | Muda? | Para quê |
|---|---|---|
| `qa-<sha7>` / `prod-<sha7>` | Nunca | O que está no ambiente; é o alvo do deploy e do rollback |
| `qa` / `prod` | Sim | Conveniência: aponta para o mais recente |

Sem versionamento semântico (não há processo de release). PR não gera imagem;
merge em `develop` publica `qa-*`, merge em `main` publica `prod-*`.

Passos manuais, uma vez: permitir pacotes públicos na organização e, depois do
primeiro push de cada imagem, mudá-la de privada para **pública** (senão o pod
fica em `ImagePullBackOff`). Nunca apague as tags `qa`, `prod` e as `<env>-<sha>`
recentes: o nó volta ao registro a cada reinício.

## 7. Kubernetes (k3s na EC2)

k3s é Kubernetes certificado pela CNCF (mesma API e `kubectl`), sem o custo do
EKS. Perde-se alta disponibilidade, que não é requisito. Um nó, Traefik
embutido, sem load balancer nem NAT Gateway.

```text
EC2 t3.medium (Amazon Linux 2023) + Elastic IP
└── k3s
    ├── volta-qa    → api, api-redis, chatbot (replicas 0 por padrão)
    └── volta-prod  → api, api-redis, chatbot
```

```text
kubernetes/
├── namespace.yaml
├── base/        api/ api-redis/ chatbot/ ingress.yaml
└── overlays/
    ├── qa/      réplicas 0, HTTPS (cert-manager), logs DEBUG, LangSmith
    └── prod/    mais CPU/memória, logs enxutos
```

**Redis.** Não roda no cluster: a `api-redis` usa o **Redis Cloud**. Endereço,
porta e credenciais ficam no `api-redis-secrets`. Como o Redis só guarda índices
derivados, se os dados se perderem o ranking é recriado pela carga em lote a
partir do PostgreSQL.

**Endereços.** Sem domínio próprio: o `sslip.io` resolve o IP embutido no nome.
Somente o QA tem HTTPS (Let's Encrypt via cert-manager).

```text
api.qa.<EIP>.sslip.io      → api        (8080)      api.<EIP>.sslip.io      (prod)
ranking.qa.<EIP>.sslip.io  → api-redis  (8081)      ranking.<EIP>.sslip.io  (prod)
chat.qa.<EIP>.sslip.io     → chatbot    (8000)      chat.<EIP>.sslip.io     (prod)
```

**Saúde.** `api` e `api-redis`: `/actuator/health/readiness` e `/liveness` (o
readiness da `api-redis` inclui a conexão com o Redis). `chatbot`: `/health/ready`
e `/health/live`; o smoke test usa `/health`. Sem probes o `rollout status`
declararia sucesso antes de a aplicação subir.

**Secrets.** `Secret` do Kubernetes criado à mão, uma vez por namespace
(`api-secrets`, `api-redis-secrets`, `chatbot-secrets`). Sem Sealed Secrets: a
complexidade não compensa. Detalhes em [`03-secrets.md`](03-secrets.md).

**Deploy por SSH.** A chave pública fica no `authorized_keys` da instância e a
privada no secret `SSH_PRIVATE_KEY`. Operação do cluster em
[`06-cluster-k3s.md`](06-cluster-k3s.md).

## 8. Website na Vercel

Importado do GitHub pelo app da Vercel: `main` é produção, `develop` e PRs geram
preview. O navegador chama caminhos relativos (`/api`, `/chat-api`,
`/ranking-api`) e o `vercel.json` do Website os repassa por rewrite ao backend.
Variáveis `VITE_*` são gravadas no build e **nunca podem conter segredo**. Rollback:
promover um deployment anterior no painel. Detalhes em
[`07-vercel-website.md`](07-vercel-website.md).

## 9. Dados e serviços externos

| Serviço | Uso | Observação |
|---|---|---|
| Neon (PostgreSQL) | Banco da `api` e consultas do chatbot | Uma branch por ambiente (`qa`, `prod`); não expira, mas hiberna: acorde-o antes de demonstrar |
| MongoDB Atlas (M0) | Sessões e checkpoints do chatbot | Bancos `volta_qa` e `volta_prod` |
| Qdrant | RAG do chatbot em QA/produção | Sem `QDRANT_URL` o chatbot cai para FAISS local, que não vai na imagem |
| Redis Cloud | Ranking e índice GEO da `api-redis` | Credenciais no `api-redis-secrets`; TLS conforme o endpoint |
| Cloudinary | Fotos de ocorrência e de perfil | Upload direto do cliente por preset sem assinatura; nada de segredo no front |
| Firebase | FCM (push) e Firestore no Mobile | Só no app |
| LangSmith | Tracing do chatbot | Opcional (`VOLTA_LANGSMITH_ENABLED`); ativo em QA |
| SMTP (ex.: Brevo) | Recuperação de senha na `api` | Opcional; sem `MAIL_*` nenhum e-mail é enviado |

## 10. Segurança e secrets

Onde cada segredo mora e como criá-lo: [`03-secrets.md`](03-secrets.md).

| Informação | Onde fica |
|---|---|
| `SSH_PRIVATE_KEY`, `GHCR_CLEANUP_TOKEN`, `AWS_*` (só ligar/desligar a EC2) | GitHub Secrets do `volta-devops` |
| `SSH_HOST` (Elastic IP) | GitHub Variable do `volta-devops` |
| `DEVOPS_DISPATCH_TOKEN` (PAT) | GitHub Secret de cada repositório de aplicação |
| Senhas de banco, `JWT_KEY`, chaves de LLM, Qdrant, SMTP | `Secret` do namespace no k3s |
| `VITE_*` | Variable na Vercel (**nunca secret**) |
| `.env.example` | Versionado, sem valores |
| `.env` | Nunca versionado |

Segredos da aplicação **não ficam no GitHub**: quem precisa deles é o container,
não a esteira. Use `JWT_KEY` diferente em QA e produção.

Como imagens e repositórios são públicos:

- o `.dockerignore` exclui `.env`, `*.pem`, `*.key` e `application-local.yml`;
- `application.yml` só tem placeholders; nada de segredo em `ENV`/`ARG`;
- segredo apagado continua no histórico do Git: troque o valor.

Também ligados: Dependabot, CodeQL, actions oficiais em `@v4` e SHA completo para
as de terceiros. Fora do escopo: DAST, assinatura de imagem, SBOM e scan de
container.

## 11. Docker Compose

`docker-compose/docker-compose.yaml` sobe `postgres`, `mongo`, `redis`, `api`,
`api-redis` e `chatbot` (`ENVIRONMENT=qa`). Website (`npm run dev`) e Mobile
(Android Studio) ficam de fora. Os repositórios precisam estar **lado a lado**
(`volta-api-core`, `volta-api-redis`, `volta-chatbot`, `volta-devops`), pois o
Compose usa caminhos relativos. Uso em
[`docker-compose/README.md`](../docker-compose/README.md).

Planejado, ainda não existe: *profiles*, pgAdmin/mongo-express e um
`docker-compose.ghcr.yml` com as imagens publicadas.

## 12. Fluxo completo

```text
Ticket SCRUM-1858 → feat/SCRUM-1858 → PR para develop
   CI: validate-pr ‖ build-test → ruleset (checks + 1 aprovação) → squash merge
   │
   ▼ push em develop
build-test → build/push (qa-<sha>, qa) → dispatch → kustomize → SSH → kubectl apply -k qa
   → rollout + smoke test → validação manual em QA
   │
   ▼ PR develop → main (merge commit, CODEOWNER, branch atualizada)
build-test → build/push (prod-<sha>, prod) → ⏸ aprovação do Environment prod
   → kubectl apply -k prod → smoke test
```

Fora da esteira de deploy: Mobile (APK como artifact), Database, BI e landing
pages. O Website segue o fluxo da Vercel.

**Portões de produção:** CI no PR, validação em QA, PR aprovado por CODEOWNER, CI
no merge, imagem `prod-<sha>`, aprovação manual do Environment, deploy com smoke
test. Só a aprovação do PR e a do Environment são humanas.

**Validação em QA** (checklist no template do PR `develop → main`): fluxo
principal ponta a ponta com o Mobile de debug apontando para a API de QA,
funcionalidade nova, regressão, chatbot respondendo com o banco de QA, ranking
(`api-redis`) respondendo e o preview do Website.

### Rollback

Em ordem de rapidez (passo a passo em
[`04-runbook-deploy.md`](04-runbook-deploy.md#voltar-uma-versão-rollback)):

1. `scripts/rollback.sh`: volta o Deployment à revisão anterior ou a uma tag
   exata, em segundos;
2. workflow **Deploy** com uma tag anterior (1–2 min, sem rebuild nem PR);
3. `git revert` de manifesto, quando uma mudança versionada causou o problema.

Website: promova um deployment anterior na Vercel.

## 13. Alternativas comparadas

| Tema | Escolhido | Alternativas descartadas |
|---|---|---|
| Repositórios | Multi-repo: CI independente e contribuição individual visível | Monorepo |
| Visibilidade | Públicos: ruleset, Environments e CODEOWNERS grátis | Privados (sem esses recursos no plano gratuito) |
| Workflows | CI local por linguagem; build e deploy reutilizáveis | Duplicar tudo; composite action; centralizar o CI |
| Registro | GHCR: login com `GITHUB_TOKEN`, sem limite relevante | Docker Hub |
| Website | Vercel: preview por PR, nada a manter | Render Static Site; container nginx |
| Postgres | Neon: não expira e tem branches (QA e PROD num projeto) | Render Free (expira em 30 dias); Aiven Free |
| Orquestração | k3s: Kubernetes sem custo de plano de controle | EKS (~US$ 73/mês); Render (não é Kubernetes) |
| Deploy | `repository_dispatch` + SSH | OIDC + SSM (sem IAM); Argo CD/Flux (pesam no nó único) |
| Fotos | Cloudinary direto do cliente: a API não trafega arquivo | Upload pela API (512 MB não aguentam usuários simultâneos) |
| Branches | `main` + `develop` | Git Flow completo; trunk-based (exige feature flags) |

Decisões conscientes: nó único é ponto único de falha (alta disponibilidade
custaria ~4x o orçamento sem ajudar no que é avaliado) e o histórico do Actions
substitui o GitOps.

**Recomendações.** Ligue o ruleset só depois de o CI rodar verde uma vez (copie o
nome exato do check pela interface). Crie a tag `v1` neste repositório antes de
usar os reutilizáveis. Crie o Elastic IP na primeira sessão do lab. Configure o
AWS Budget (alertas em US$ 10, 25 e 40). Mantenha um `.env.example` completo em
cada repositório. Rode `docker run --rm -it ghcr.io/app-volta/api:prod sh` uma
vez para ver o que a imagem pública expõe. E documente a decisão, não só a
configuração: explicar por que o deploy fixa `<env>-<sha>` ou por que k3s e não
EKS vale mais do que recitar o YAML.

---

*Mantido pelo time de DevOps · Projeto Volta*
