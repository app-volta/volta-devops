# Runbook de deploy

Guia rápido para as situações do dia a dia. Para detalhes do cluster, veja
[`06-cluster-k3s.md`](06-cluster-k3s.md).

## Como um deploy acontece

```text
Merge em develop/main
   └─► repositório da aplicação gera a imagem (qa-<sha> ou prod-<sha>) no GHCR
        └─► avisa este repositório (repository_dispatch)
             └─► workflow "Deploy" valida o aviso
                  └─► conecta na EC2 por SSH e roda kubectl apply
                       └─► espera o serviço ficar saudável
```

Em **produção**, o deploy fica parado esperando uma pessoa aprovar no GitHub
(*Environment `prod`*). Em QA é automático.

## Antes de tudo: o cluster está ligado?

**Actions → "Ligar e desligar o cluster" → Run workflow → `status`**

Se estiver desligado, rode com `start` e espere terminar. Se o workflow falhar
com erro de credencial, veja [Renovar a sessão do Learner Lab](#renovar-a-sessão-do-learner-lab).

## Fazer um deploy manual

Útil para reimplantar uma versão antiga ou testar sem fazer novo build.

1. **Actions → "Deploy" → Run workflow**
2. Preencha:
   - `service`: `api`, `api-redis` ou `chatbot`
   - `environment`: `qa` ou `prod`
   - `image-tag`: ex. `prod-a1b2c3d`
3. Em produção, aguarde e aprove o job quando o GitHub pedir.

O workflow recusa:

- tag fora do padrão `<env>-<sha7>`;
- tag de um ambiente aplicada em outro (por exemplo, `qa-...` indo para `prod`).

Cada deploy mexe **apenas no serviço escolhido**. As imagens dos outros serviços
são preservadas.

## Testar o chatbot em QA (`qa-smoke`)

1. **Actions → "Deploy" → Run workflow**
2. `service=chatbot`, `environment=qa`, a tag de QA e marque **`qa-smoke`**.

O workflow liga uma réplica, espera ficar pronta, chama `GET /health` por HTTPS e
**sempre** tenta voltar para `replicas=0` no final, mesmo se o teste falhar.

> Isso só prova que o serviço responde. Sessão e chat autenticados ainda
> precisam ser testados pelo app mobile.

## Voltar uma versão (rollback)

Escolha o caminho mais adequado:

### 1. Emergência (segundos): script local

Não depende do GitHub estar no ar.

```bash
./scripts/rollback.sh prod api                 # volta uma revisão
./scripts/rollback.sh prod api prod-a1b2c3d    # volta para uma tag exata
./scripts/rollback.sh prod api --history       # só lista as revisões
```

Depois que o serviço se recuperar, **registre a tag boa** rodando o workflow
"Deploy" manual com ela. Assim o histórico do Actions fica correto.

### 2. Sem urgência (1–2 min): workflow Deploy

Rode o deploy manual (acima) com a tag anterior. Não precisa de PR nem de
rebuild.

### 3. Mudança de manifesto que causou o problema

Use `git revert` da mudança e abra um PR normalmente.

### Website

Na Vercel, promova um deployment anterior pelo painel.

## Ver logs e estado

Conecte na EC2:

```bash
ssh -i ~/.ssh/volta-k3s.pem ec2-user@<EIP>
```

E use:

```bash
kubectl get pods -A                                  # o que está rodando
kubectl -n volta-prod logs deploy/api --tail=100     # logs da API em produção
kubectl -n volta-qa describe pod <nome-do-pod>       # por que um pod não sobe
sudo journalctl -u k3s -n 100                        # logs do Kubernetes
```

## Renovar a sessão do Learner Lab

A sessão expira a cada ~4 horas. Quando isso acontece, o script local e o
workflow de ligar/desligar falham com erro de credencial.

1. No AWS Academy, abra **AWS Details → AWS CLI → Show**.
2. Rode o script e cole o bloco:

```bash
./scripts/update-aws-session.sh          # atualiza ~/.aws/credentials
./scripts/update-aws-session.sh --gh     # também atualiza os 3 secrets no GitHub
```

(Para usar `--gh`, é preciso ter o `gh` instalado e logado.)

## Quem aprova produção?

Qualquer pessoa configurada como *Required reviewer* no Environment `prod` do
repositório. Vá em *Settings → Environments → prod* para ver a lista.

## O deploy falhou: e agora?

| O que apareceu | O que provavelmente é | O que fazer |
|---|---|---|
| "Serviço inválido" / "Ambiente inválido" | Dados do dispatch errados | Confira `image-name` e `environment` no workflow da aplicação |
| "Tag fora do padrão" | Tag não é `<env>-<sha7>` | Use uma tag imutável, como `qa-a1b2c3d` |
| "A tag não pertence ao ambiente" | Tentou usar tag de QA em prod (ou o inverso) | Use a tag do ambiente correto |
| Falha na conexão SSH | EC2 desligada ou `SSH_HOST` errado | Rode `start`; confira a variável `SSH_HOST` |
| `ImagePullBackOff` | Imagem ainda está **privada** no GHCR | Em *Package settings → Change visibility*, deixe como **Public** |
| `CrashLoopBackOff` | Imagem na arquitetura errada ou erro de configuração | Garanta `linux/amd64`; olhe os logs do pod |
| Rollout expira | Aplicação não ficou saudável | Veja os logs do pod e o health check |
| Nada acontece em QA após o deploy | QA está com `replicas=0` por padrão | Escale manualmente (veja [`02-ambientes.md`](02-ambientes.md)) |

## Checklist antes de uma apresentação

- [ ] Renovar a sessão do lab e conferir os secrets `AWS_*`
- [ ] Ligar o cluster (`start`) pelo menos **10 minutos antes**
- [ ] Acessar o banco (Neon) uma vez, porque ele "dorme" quando parado
- [ ] Se for mostrar QA, escalar as réplicas
- [ ] Pausar o auto-stop, se a apresentação tiver pausas longas:
  ```bash
  aws cloudwatch disable-alarm-actions --alarm-names volta-k3s-autostop
  ```
- [ ] Depois, reativar com `enable-alarm-actions`
