# Cluster k3s — provisionamento e operação

> Repositório: `app-volta/volta-devops` · Caminho: `docs/06-cluster-k3s.md`
> Complementa a seção 17 de [`01-arquitetura-cicd.md`](01-arquitetura-cicd.md),
> que explica **por que** a arquitetura é essa. Aqui está **como operar**.

---

## O que existe

```text
EC2 t3.medium (Amazon Linux 2023, 30 GB gp3) + Elastic IP
└── k3s single-node, Traefik embutido
    ├── namespace volta-qa
    └── namespace volta-prod

Security group: 22 (SSH do deploy), 80 e 443 (Traefik)
CloudWatch: alarme de auto-stop após 15 min sem tráfego de rede
```

Sem ELB, sem NAT Gateway, sem EKS — os três maiores sorvedouros de crédito numa
conta AWS pequena.

**Divisão de responsabilidade:**

| Quando | Como | Frequência |
|---|---|---|
| Criar a máquina e o cluster | Script local (`provision-ec2-k3s.sh`) | Uma vez (ou se precisar recriar do zero) |
| Ligar / desligar / ver status | Pela pipeline (GitHub Actions) | Todo dia de uso |

O script de provisionamento fica **versionado no repositório**, mesmo rodando
raramente: é o registro exato de como o cluster foi criado — permissões, tipo
de instância, disco, IP fixo, alarme de auto-stop — servindo tanto de
documentação viva quanto de forma de recriar tudo caso precise.

---

## Pré-requisitos

1. **AWS CLI v2** e **jq** instalados na sua máquina.
2. **Sessão do Learner Lab iniciada.** Em *AWS Details → AWS CLI → Show*, copie
   o bloco e cole em `~/.aws/credentials`. Vale por **4 horas**; depois disso o
   script falha com erro de credencial — é esperado, basta recolar.
3. Região `us-east-1` (ou `us-west-2`; o lab não permite outras).

Verifique antes de começar:

```bash
aws sts get-caller-identity
```

---

## Provisionamento (uma vez, local)

```bash
./scripts/provision-ec2-k3s.sh
```

O script é **idempotente** — rodar de novo não duplica nada, só reporta o que já
existe. Ele executa, em ordem:

| Passo | O que faz | Se já existir |
|---|---|---|
| 1 | Cria o security group `volta-k3s-sg` e libera as portas 22, 80 e 443 | Reaproveita |
| 2 | Cria a chave de acesso `volta-k3s` e salva em `~/.ssh/volta-k3s.pem` | Avisa se a chave local sumiu |
| 3 | Sobe a EC2 já com o "user data" que instala o k3s sozinho no primeiro boot (`cloud-init-k3s.sh`) | Reaproveita |
| 4 | Aloca e associa o Elastic IP (endereço fixo) | Reaproveita e reassocia |
| 5 | Cria o alarme de auto-stop no CloudWatch | Sobrescreve |

Ao final ele imprime o Elastic IP, os endereços do site e os próximos passos.

### Depois de provisionar

Duas configurações manuais no GitHub, uma vez só:

1. **Settings → Secrets and variables → Actions → New repository secret**:
   nome `SSH_PRIVATE_KEY`, valor = todo o conteúdo do arquivo
   `~/.ssh/volta-k3s.pem` (incluindo as linhas de início e fim).
2. Nos Environments `qa` e `prod` (**Settings → Environments**): uma variable
   `SSH_HOST` = o Elastic IP que o script imprimiu.

O primeiro boot leva ~3 minutos (instala pacotes, baixa o k3s, cria os
namespaces). Acompanhe com:

```bash
ssh -i ~/.ssh/volta-k3s.pem ec2-user@<EIP> 'sudo tail -f /var/log/cloud-init-output.log'
```

---

## Operação do dia a dia (pela pipeline)

Não precisa terminal nem AWS CLI para isso. No GitHub:

**Actions → "Ligar e desligar o cluster" → Run workflow → escolha uma ação:**

| Ação | O que faz |
|---|---|
| `start` | Liga a máquina e espera o Kubernetes responder antes de terminar |
| `stop` | Desliga a máquina (o disco e o IP continuam sendo cobrados) |
| `status` | Mostra se está ligada, o endereço e o que está rodando |

Isso é tudo o que qualquer pessoa do time precisa saber para usar o cluster no
dia a dia — não precisa mexer em script nem editar arquivo local.

> Esse workflow só funciona enquanto os secrets `AWS_ACCESS_KEY_ID`,
> `AWS_SECRET_ACCESS_KEY` e `AWS_SESSION_TOKEN` estiverem válidos. No Learner
> Lab, eles **expiram a cada 4 horas** — é uma limitação do ambiente de estudo,
> não deste projeto. Quando expirarem, o workflow falha com erro de credencial;
> pegue os valores novos em *AWS Details → AWS CLI → Show* e cole de novo
> nesses três secrets.

### Auto-stop

A instância para sozinha quando o tráfego de rede fica muito baixo por ~15
minutos seguidos — o alarme do CloudWatch criado no provisionamento cuida
disso, sem nada adicional rodando.

Consequência prática: **se alguém deixar um acompanhamento de log aberto, a
instância não desliga.** E, ao contrário, uma pausa longa numa demonstração
pode derrubar o cluster no meio dela. Para suspender temporariamente:

```bash
aws cloudwatch disable-alarm-actions --alarm-names volta-k3s-autostop
# ... depois da apresentação ...
aws cloudwatch enable-alarm-actions --alarm-names volta-k3s-autostop
```

### Antes de uma apresentação

Ligue o cluster (`start` na pipeline) com **10 minutos** de antecedência: a
máquina leva ~1 minuto para subir, o Kubernetes mais um pouco, o ambiente de QA
precisa ser "acordado" (fica desligado por padrão para economizar memória) e o
banco de dados (Neon) também demora um pouco mais no primeiro acesso depois de
um período parado.

---

## Custo

| Item | Cobrado quando | Estimativa |
|---|---|---|
| EC2 t3.medium | Só ligada | ~US$ 0,0416/h |
| Disco (30 GB) | **Sempre**, mesmo desligada | ~US$ 2,40/mês |
| Elastic IP | **Sempre** | ~US$ 3,60/mês |
| Armazenamento de fotos (S3) + transferência | Por uso | ~US$ 1/mês |

| Regime de uso | Custo/mês | Cabe nos US$ 50 do crédito? |
|---|---|---|
| ~2 h/dia | ~US$ 10 | Sim, com folga |
| ~8 h/dia | ~US$ 17 | Sim |
| Ligada o tempo todo | ~US$ 37 | Consome o crédito em ~5 semanas |

Configure um AWS Budget com alertas em US$ 10, US$ 25 e US$ 40 para não ser
pego de surpresa.

---

## Diagnóstico — o que fazer quando algo dá errado

| Sintoma | O que provavelmente é |
|---|---|
| Script local falha com erro de credencial | Sessão do lab expirou (4h) — recole `~/.aws/credentials` |
| Pipeline falha com erro de credencial | Os três secrets AWS expiraram — atualize-os no GitHub |
| SSH recusa a conexão | A máquina está desligada — rode `start` na pipeline |
| SSH pede senha em vez de aceitar a chave | Use `-i ~/.ssh/volta-k3s.pem` |
| `kubectl` não encontrado por SSH | O primeiro boot ainda não terminou; veja `/var/log/cloud-init-output.log` |
| Aplicação não sobe (`ImagePullBackOff`) | A imagem publicada no registro ainda está marcada como privada |
| Aplicação trava reiniciando (`CrashLoopBackOff`) | Imagem construída para o processador errado — force `linux/amd64` |
| O endereço mudou sozinho | O Elastic IP se desassociou — rode `provision-ec2-k3s.sh` de novo |
| O cluster desliga sozinho no meio do uso | Comportamento esperado do auto-stop por inatividade |

Comandos úteis rodando dentro da máquina, por SSH:

```bash
kubectl get nodes                                  # a máquina está saudável?
kubectl get pods -A                                # o que está rodando
kubectl -n volta-qa logs deploy/api --tail=100     # últimas linhas de log da API em QA
sudo journalctl -u k3s -n 100                      # log do próprio Kubernetes
```

---

## Recriar o cluster do zero

Se algo ficar irrecuperável, encerre a instância e rode o script de novo. O
Elastic IP, o security group e a chave sobrevivem — o script os reaproveita, e
os endereços do site continuam os mesmos.

```bash
INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=volta-k3s" \
            "Name=instance-state-name,Values=running,stopped" \
  --query 'Reservations[].Instances[0].InstanceId' --output text)

aws ec2 terminate-instances --instance-ids "$INSTANCE_ID"
aws ec2 wait instance-terminated --instance-ids "$INSTANCE_ID"

./scripts/provision-ec2-k3s.sh
```

Depois de recriar, lembre-se de recadastrar os segredos da aplicação (senha do
banco, chaves de API) dentro do cluster — eles não ficam guardados em lugar
nenhum do Git, por decisão de segurança registrada na seção 17 da arquitetura.

---

## Arquivos

| Arquivo | Papel |
|---|---|
| `scripts/lib-aws.sh` | Convenções e funções compartilhadas (não executar direto) |
| `scripts/provision-ec2-k3s.sh` | Provisionamento idempotente completo — roda local, uma vez |
| `scripts/cloud-init-k3s.sh` | User data: instala k3s, kustomize e cria os namespaces no primeiro boot |
| `.github/workflows/ec2-power.yaml` | Botão do dia a dia: liga, desliga e mostra status do cluster |

Variáveis de ambiente reconhecidas pelos scripts: `AWS_REGION`,
`INSTANCE_NAME`, `INSTANCE_TYPE`, `VOLUME_SIZE_GB`, `KEY_NAME`, `KEY_FILE`,
`SSH_CIDR`, `IDLE_MINUTES`.
