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

## No GitHub (repositórios de aplicação: API, Chatbot...)

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
  --from-literal=JWT_KEY='valor-de-qa' \
  --from-literal=SPRING_DATASOURCE_PASSWORD='senha-do-neon-qa'
```

Dicas importantes:

- Use **valores diferentes** em QA e produção. Principalmente a chave do JWT: assim
  um token emitido em QA não vale em produção.
- Os nomes das chaves (`JWT_KEY` etc.) precisam ser os que a aplicação lê. Para
  o Chatbot, use o `docker-compose/.env.example` como lista de referência.
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
