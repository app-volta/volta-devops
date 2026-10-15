# Secrets e variáveis

Este repositório é **público**. Tudo que for commitado pode ser lido por
qualquer pessoa, e apagar depois **não resolve**: o dado continua no histórico
do Git. Por isso, senhas e chaves nunca entram no código.

## Regra de ouro

| Tipo de dado | Onde fica |
|---|---|
| Quem precisa é o **pipeline** (SSH, tokens do GitHub) | GitHub Secrets / Variables |
| Quem precisa é a **aplicação** rodando (senha de banco, chave de IA) | `Secret` do Kubernetes, dentro do cluster |
| Configuração que não é secreta (porta, nível de log) | Git, no `configmap.yaml` do overlay |

## No GitHub (repositório `volta-devops`)

*Settings → Secrets and variables → Actions*

| Nome | Tipo | Para quê |
|---|---|---|
| `SSH_PRIVATE_KEY` | Secret | Chave privada para o deploy entrar na EC2 por SSH. É o conteúdo de `~/.ssh/volta-k3s.pem` |
| `SSH_HOST` | Variable | Elastic IP da instância |
| `GHCR_CLEANUP_TOKEN` | Secret | Token (PAT) com `delete:packages` para a limpeza mensal do GHCR |
| `AWS_ACCESS_KEY_ID` | Secret | Credencial do Learner Lab, usada por `ec2-power.yaml` |
| `AWS_SECRET_ACCESS_KEY` | Secret | Idem |
| `AWS_SESSION_TOKEN` | Secret | Idem |

`SSH_HOST` é uma Variable (não Secret) porque o IP não é sensível, e ela vale
para o repositório inteiro, já que existe um cluster só.

> As três credenciais AWS **expiram a cada 4 horas**. Veja como renová-las em
> [`04-runbook-deploy.md`](04-runbook-deploy.md#renovar-a-sessão-do-learner-lab).

## No GitHub (repositórios de aplicação: API, API Redis, Chatbot...)

| Nome | Tipo | Para quê |
|---|---|---|
| `DEVOPS_DISPATCH_TOKEN` | Secret | Token (PAT) com permissão de escrita no `volta-devops`. Serve para avisar este repositório que há uma imagem nova |

Sem esse token, o workflow `reusable-docker-build-push.yaml` falha de
propósito. O `GITHUB_TOKEN` automático não consegue disparar workflows em
outro repositório.

## No cluster (Secrets do Kubernetes)

Cada serviço lê um `Secret` com o nome abaixo, em cada namespace:

| Secret | Usado por |
|---|---|
| `api-secrets` | `api` |
| `api-redis-secrets` | `api-redis` |
| `chatbot-secrets` | `chatbot` |

Eles são criados **à mão, uma vez por namespace**. Exemplo:

```bash
# dentro da EC2, via SSH
kubectl -n volta-qa create secret generic api-secrets \
  --from-literal=DATABASE_HOST='ep-xxxx.sa-east-1.aws.neon.tech' \
  --from-literal=DATABASE_NAME='nome-do-banco-qa' \
  --from-literal=DATABASE_USERNAME='usuario-do-neon-qa' \
  --from-literal=DATABASE_PASSWORD='senha-do-neon-qa' \
  --from-literal=JWT_KEY='valor-de-qa-com-mais-de-32-bytes' \
  --from-literal=JWT_EXPIRATION='3600000'
```

### O que cada Secret precisa ter

Os nomes abaixo são os que cada aplicação lê (conferidos nos repositórios).

| Secret | Obrigatórias | Opcionais |
|---|---|---|
| `api-secrets` | `DATABASE_HOST`, `DATABASE_NAME`, `DATABASE_USERNAME`, `DATABASE_PASSWORD`, `JWT_KEY`, `JWT_EXPIRATION` | `DATABASE_POOL_SIZE` (padrão 5), `SERVER_PORT` (padrão 8080), `SWAGGER_USERNAME`, `SWAGGER_PASSWORD`, `ADMIN_EMAIL`, `ADMIN_PASSWORD`, `ADMIN_COMPANY_ID` |
| `api-redis-secrets` | `JWT_KEY` | `JWT_EXPIRATION` |
| `chatbot-secrets` | `POSTGRES_DSN`, `MONGO_URI`, `JWT_KEY`, `GEMINI_API_KEY`, `GROQ_API_KEY` | `CORS_ORIGINS`, `QDRANT_URL`, `QDRANT_API_KEY`, `INGESTION_API_KEY`, `COOPERATIVE_A2A_BASE_URL`, `COOPERATIVE_A2A_HMAC_SECRET`, `LANGSMITH_API_KEY` |

O `REDIS_HOST` e o `REDIS_PORT` da `api-redis` **não são secretos**: vêm do
ConfigMap `api-redis-config` (`redis:6379`, o Service do Redis do cluster).


Dicas importantes:

- Use **valores diferentes** em QA e produção. Principalmente a chave do JWT: assim
  um token emitido em QA não vale em produção.
- O `JWT_KEY` precisa ser **igual na `api`, na `api-redis` e no `chatbot`
  dentro do mesmo ambiente** (a `api` emite o token, as outras o validam) e
  **diferente entre QA e produção**.
- Os nomes das chaves precisam ser os que a aplicação lê (tabela acima).
- Sem `QDRANT_URL`, o chatbot só consegue usar um índice FAISS, e o índice não
  vai na imagem (`data/faiss` está no `.dockerignore`). Para o RAG funcionar em
  QA/produção, publique os documentos num Qdrant (`scripts/ingest_rag.py`, no
  repositório do chatbot) e informe `QDRANT_URL` e `QDRANT_API_KEY`.
- Se recriar o cluster do zero, **os secrets somem** e precisam ser criados de
  novo.
- Para ver quais chaves existem (sem mostrar os valores):
  `kubectl -n volta-qa describe secret api-secrets`

## O que é público na imagem Docker

As imagens no GHCR são públicas. Quem baixar a imagem consegue ver tudo que
está dentro dela. Então:

- o `.dockerignore` deve excluir `.env`, `*.pem` e `*.key`;
- `application.yml` só pode ter placeholders, como `${DB_PASSWORD}`;
- nenhuma senha em `ENV` ou `ARG` do Dockerfile.

## Credenciais AWS

Nenhuma credencial AWS é guardada para a **aplicação**. Quando a API precisa do
S3, a EC2 recebe credenciais temporárias sozinha (pelo `LabInstanceProfile`).

As credenciais guardadas no GitHub (`AWS_*`) servem apenas para ligar e desligar
a instância, e expiram junto com a sessão do lab.

## Variáveis do Website (Vercel)

Variáveis `VITE_*` são **embutidas no JavaScript** que o navegador baixa.
Portanto, **nunca** coloque segredo em uma variável `VITE_*`. Veja
[`07-vercel-website.md`](07-vercel-website.md).

## Se um secret vazar

1. Troque o valor imediatamente (gere um novo token, nova senha, nova chave).
2. Atualize no GitHub e/ou no `kubectl create secret` (use `--dry-run=client -o yaml | kubectl apply -f -` para sobrescrever).
3. Reinicie os pods: `kubectl -n <namespace> rollout restart deployment/<serviço>`.
4. Não adianta só apagar o commit: considere o valor antigo como comprometido.
