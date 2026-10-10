# Cluster k3s: criar e operar

> Complementa a seção 17 de [`01-arquitetura-cicd.md`](01-arquitetura-cicd.md),
> que explica **por que** a arquitetura é assim. Aqui está **como operar**.
> Para deploy e rollback, veja também [`04-runbook-deploy.md`](04-runbook-deploy.md).

## O que existe

```text
EC2 t3.medium (Amazon Linux 2023, disco de 30 GB) + Elastic IP (IP fixo)
└── k3s (Kubernetes leve, com Traefik embutido)
    ├── namespace volta-qa
    └── namespace volta-prod

Firewall (security group): portas 22 (SSH), 80 e 443 (Traefik)
CloudWatch: desliga a máquina após ~15 min sem tráfego de rede
```

Não usamos load balancer, NAT Gateway nem EKS. São os itens que mais gastam
crédito numa conta AWS pequena.

### Quem faz o quê

| Tarefa | Como | Quando |
|---|---|---|
| Criar a máquina e o cluster | Script local (`provision-ec2-k3s.sh`) | Uma vez (ou para recriar do zero) |
| Ligar, desligar e ver o estado | Workflow no GitHub | Todo dia |

O script fica no repositório mesmo rodando pouco. Ele é o registro de **como o
cluster foi criado** e permite recriar tudo.

---

## Pré-requisitos

1. **AWS CLI v2** e **jq** instalados.
2. **Sessão do Learner Lab ativa.** Em *AWS Details → AWS CLI → Show*, copie o
   bloco para `~/.aws/credentials`. Vale por **4 horas**; depois, o script falha
   com erro de credencial, e é só colar de novo (ou use
   `./scripts/update-aws-session.sh`).
3. Região `us-east-1` (ou `us-west-2`).

Confira se está tudo certo:

```bash
aws sts get-caller-identity
```

---

## Criar o cluster (uma vez)

```bash
./scripts/provision-ec2-k3s.sh
```

O script é **idempotente**: rodar de novo não duplica nada, só informa o que já
existe. Os passos:

| # | O que faz | Se já existir |
|---|---|---|
| 1 | Cria o firewall `volta-k3s-sg` e libera as portas 22, 80 e 443 | Reaproveita |
| 2 | Cria a chave de acesso `volta-k3s` em `~/.ssh/volta-k3s.pem` | Avisa se a chave local sumiu |
| 3 | Sobe a EC2, que instala o k3s sozinha no primeiro boot (`cloud-init-k3s.sh`) | Reaproveita |
| 4 | Cria e associa o Elastic IP | Reaproveita |
| 5 | Cria o alarme de desligamento automático | Sobrescreve |

No final, ele mostra o Elastic IP, os endereços e os próximos passos.

### Depois de criar: configurar o GitHub

Duas configurações manuais, uma única vez, em **Settings → Secrets and variables
→ Actions**:

1. **Secret** `SSH_PRIVATE_KEY`: todo o conteúdo de `~/.ssh/volta-k3s.pem`
   (inclusive as linhas de início e fim).
2. **Variable** `SSH_HOST`: o Elastic IP que o script mostrou. É variável do
   **repositório**, não de Environment, porque existe só um cluster.

Demais secrets: veja [`03-secrets.md`](03-secrets.md).

O primeiro boot leva ~3 minutos. Para acompanhar:

```bash
ssh -i ~/.ssh/volta-k3s.pem ec2-user@<EIP> 'sudo tail -f /var/log/cloud-init-output.log'
```

---

## Operação diária

Não precisa de terminal nem de AWS CLI.

**Actions → "Ligar e desligar o cluster" → Run workflow → escolha uma ação**

| Ação | O que faz |
|---|---|
| `start` | Liga a máquina e só termina quando o Kubernetes responde |
| `stop` | Desliga a máquina (disco e IP continuam cobrados) |
| `status` | Mostra se está ligada, o endereço e o que está rodando |

> Esse workflow depende dos secrets `AWS_ACCESS_KEY_ID`,
> `AWS_SECRET_ACCESS_KEY` e `AWS_SESSION_TOKEN`. No Learner Lab eles **expiram a
> cada 4 horas**. É uma limitação do ambiente de estudo, não do projeto. Quando
> o workflow falhar com erro de credencial, renove os três secrets (use
> `./scripts/update-aws-session.sh --gh`).

### Desligamento automático

A máquina desliga sozinha quando o tráfego de rede fica muito baixo por ~15
minutos. Na prática:

- se alguém deixar um `logs -f` aberto, ela **não** desliga;
- se houver uma pausa longa durante uma apresentação, ela **pode** desligar.

Para suspender temporariamente:

```bash
aws cloudwatch disable-alarm-actions --alarm-names volta-k3s-autostop
# ... depois da apresentação ...
aws cloudwatch enable-alarm-actions --alarm-names volta-k3s-autostop
```

### Antes de uma apresentação

Ligue o cluster com **10 minutos** de antecedência. A máquina leva ~1 minuto
para subir, o Kubernetes um pouco mais, o QA precisa ser ligado (fica desligado
por padrão) e o Neon demora mais no primeiro acesso depois de parado.

---

## HTTPS e deploy

O deploy acontece sozinho: ao fazer merge em `develop` ou `main`, o repositório
da aplicação publica a imagem e avisa este repositório, que aplica no cluster.

No primeiro deploy em QA, o workflow instala o **cert-manager** e pede um
certificado Let's Encrypt para os três endereços (API, ranking e chat). Para
isso funcionar, as portas **80 e 443 precisam estar abertas**. O chatbot de QA
fica em `https://chat.qa.<EIP>.sslip.io`.

Para testar o chatbot de QA, use a opção `qa-smoke` do workflow **Deploy**
(passo a passo em [`04-runbook-deploy.md`](04-runbook-deploy.md#testar-o-chatbot-em-qa-qa-smoke)).

Rollback: veja [`04-runbook-deploy.md`](04-runbook-deploy.md#voltar-uma-versão-rollback).

---

## Custo

| Item | Quando é cobrado | Estimativa |
|---|---|---|
| EC2 t3.medium | Só ligada | ~US$ 0,0416/h |
| Disco (30 GB) | **Sempre** | ~US$ 2,40/mês |
| Elastic IP | **Sempre** | ~US$ 3,60/mês |
| S3 (fotos) + transferência | Por uso | ~US$ 1/mês |

| Uso | Custo/mês | Cabe nos US$ 50 de crédito? |
|---|---|---|
| ~2 h por dia | ~US$ 10 | Sim, com folga |
| ~8 h por dia | ~US$ 17 | Sim |
| Sempre ligada | ~US$ 37 | Gasta o crédito em ~5 semanas |

Crie um **AWS Budget** com alertas em US$ 10, US$ 25 e US$ 40.

---

## Diagnóstico

| Sintoma | Causa provável |
|---|---|
| Script local falha com erro de credencial | A sessão do lab expirou (4h). Cole as credenciais de novo |
| Workflow falha com erro de credencial | Os 3 secrets `AWS_*` expiraram. Atualize no GitHub |
| SSH recusa a conexão | A máquina está desligada. Rode `start` |
| SSH pede senha | Faltou o `-i ~/.ssh/volta-k3s.pem` |
| `kubectl` não encontrado | O primeiro boot ainda não terminou. Veja `/var/log/cloud-init-output.log` |
| `ImagePullBackOff` | A imagem no GHCR ainda está **privada** |
| `CrashLoopBackOff` | Imagem na arquitetura errada. Force `linux/amd64` |
| O endereço mudou | O Elastic IP se desassociou. Rode `provision-ec2-k3s.sh` de novo |
| O cluster desligou no meio do uso | Desligamento automático por inatividade |

Comandos úteis, depois de entrar na máquina por SSH:

```bash
kubectl get nodes                                  # a máquina está saudável?
kubectl get pods -A                                # o que está rodando
kubectl -n volta-qa logs deploy/api --tail=100     # últimas linhas do log da API em QA
sudo journalctl -u k3s -n 100                      # log do Kubernetes
```

---

## Recriar o cluster do zero

Se algo ficar irrecuperável, encerre a instância e rode o script de novo. O
Elastic IP, o firewall e a chave são mantidos, então os endereços continuam os
mesmos.

```bash
INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=volta-k3s" \
            "Name=instance-state-name,Values=running,stopped" \
  --query 'Reservations[].Instances[0].InstanceId' --output text)

aws ec2 terminate-instances --instance-ids "$INSTANCE_ID"
aws ec2 wait instance-terminated --instance-ids "$INSTANCE_ID"

./scripts/provision-ec2-k3s.sh
```

Depois, **recrie os secrets das aplicações** dentro do cluster (senhas de
banco, chaves de API). Eles não ficam no Git. Veja
[`03-secrets.md`](03-secrets.md).

---

## Arquivos

| Arquivo | Papel |
|---|---|
| `scripts/lib-aws.sh` | Funções e convenções compartilhadas (não execute direto) |
| `scripts/provision-ec2-k3s.sh` | Cria o cluster completo (roda local, uma vez) |
| `scripts/cloud-init-k3s.sh` | Roda no primeiro boot: instala k3s e kustomize e cria os namespaces |
| `scripts/update-aws-session.sh` | Renova as credenciais do Learner Lab |
| `scripts/rollback.sh` | Rollback de emergência, direto no cluster |
| `.github/workflows/ec2-power.yaml` | Liga, desliga e mostra o estado do cluster |
| `.github/workflows/dispatch-deploy.yaml` | Recebe o aviso de imagem nova e inicia o deploy |
| `.github/workflows/reusable-k3s-deploy.yaml` | Aplica os manifestos e espera o serviço ficar saudável |

Variáveis que os scripts aceitam: `AWS_REGION`, `INSTANCE_NAME`,
`INSTANCE_TYPE`, `VOLUME_SIZE_GB`, `KEY_NAME`, `KEY_FILE`, `SSH_CIDR`,
`IDLE_MINUTES`.
