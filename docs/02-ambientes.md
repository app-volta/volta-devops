# Ambientes: QA e Produção

> Para entender **por que** a arquitetura é assim, veja
> [`01-arquitetura-cicd.md`](01-arquitetura-cicd.md).

O Volta tem dois ambientes. Os dois rodam no **mesmo cluster**, separados por
*namespaces* (pense neles como "pastas" dentro do Kubernetes).

| | QA | Produção |
|---|---|---|
| Para que serve | Testar antes de liberar | Uso real |
| Branch que alimenta | `develop` | `main` |
| Namespace | `volta-qa` | `volta-prod` |
| GitHub Environment | `qa` | `prod` (exige aprovação manual) |
| Tag da imagem | `qa-<sha>` | `prod-<sha>` |
| Postgres (Neon) | branch `qa` | branch `prod` |
| MongoDB (Atlas) | banco `volta_qa` | banco `volta_prod` |
| Website (Vercel) | Preview | Production |
| Réplicas | **0 por padrão** (liga sob demanda) | 1 |
| Nível de log | `DEBUG` | `INFO` / `WARN` |

`<sha>` são os 7 primeiros caracteres do commit. Exemplo: `qa-a1b2c3d`.

## Endereços

Não temos domínio próprio. Usamos o [sslip.io](https://sslip.io), que
transforma um IP em nome de site. Trocando `<EIP>` pelo Elastic IP da
instância:

| Serviço | QA | Produção |
|---|---|---|
| API | `https://api.qa.<EIP>.sslip.io` | `http://api.<EIP>.sslip.io` |
| Ranking (api-redis) | `https://ranking.qa.<EIP>.sslip.io` | `http://ranking.<EIP>.sslip.io` |
| Chatbot | `https://chat.qa.<EIP>.sslip.io` | `http://chat.<EIP>.sslip.io` |

Hoje só o QA tem HTTPS (certificado Let's Encrypt, emitido pelo cert-manager).
Produção ainda está em HTTP.

## Portas dos serviços

| Serviço | Porta | Health check |
|---|---|---|
| `api` | 8080 | `/actuator/health/readiness` e `/actuator/health/liveness` |
| `api-redis` | 8081 | `/actuator/health/readiness` e `/actuator/health/liveness` |
| `chatbot` | 8000 | `/health` |

## O que cada ambiente configura

As configurações **que não são secretas** ficam no Git, em
`kubernetes/overlays/<ambiente>/configmap.yaml`. Exemplos: perfil do Spring,
porta e nível de log.

As configurações **secretas** (senhas, chaves de API) não ficam no Git. Veja
[`03-secrets.md`](03-secrets.md).

## Como o Kubernetes está organizado

```text
kubernetes/
├── namespace.yaml        # cria volta-qa e volta-prod
├── base/                 # o que é igual nos dois ambientes
│   ├── api/
│   ├── api-redis/
│   ├── chatbot/
│   └── ingress.yaml
└── overlays/             # só o que muda em cada ambiente
    ├── qa/               # réplicas=0, HTTPS, logs DEBUG
    └── prod/             # mais CPU e memória, logs enxutos
```

Essa técnica se chama **Kustomize**: a `base/` é a receita comum, e cada
`overlay` aplica só as diferenças por cima. Assim ninguém precisa copiar
arquivos entre QA e produção.

## Ligar o QA para testar

O QA começa desligado (`replicas=0`) para sobrar memória para a produção, já que
a máquina tem só 4 GB. Para testar:

```bash
# dentro da EC2, via SSH
kubectl -n volta-qa scale deployment/api --replicas=1
kubectl -n volta-qa scale deployment/chatbot --replicas=1
```

Quando terminar, volte para zero:

```bash
kubectl -n volta-qa scale deployment/api --replicas=0
kubectl -n volta-qa scale deployment/chatbot --replicas=0
```

> O deploy seguinte reaplica `replicas=0` em QA. Isso é intencional.

Para testar só o chatbot em QA pelo HTTPS, existe o atalho `qa-smoke` no
workflow **Deploy**. Veja [`04-runbook-deploy.md`](04-runbook-deploy.md).

## Atenção: o IP `0.0.0.0` nos manifestos

Nos arquivos de `kubernetes/` os endereços aparecem como
`api.qa.0.0.0.0.sslip.io`. O `0.0.0.0` é só um espaço reservado. Durante o
deploy, o workflow troca esse valor pelo IP real (variável `SSH_HOST`). **Não
substitua o IP no Git.**

## Limites do Learner Lab

O cluster roda no AWS Academy Learner Lab, que tem restrições que moldaram o
projeto:

| Limite | Efeito |
|---|---|
| Não cria usuários nem roles IAM | O deploy usa SSH, não OIDC |
| Credenciais expiram a cada 4 horas | Precisam ser renovadas (veja [`04-runbook-deploy.md`](04-runbook-deploy.md)) |
| A instância reinicia com IP novo | Por isso usamos um Elastic IP (IP fixo) |
| Só `us-east-1` e `us-west-2` | Usamos `us-east-1` |
