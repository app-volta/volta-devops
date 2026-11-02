# Vercel: Website

O Website (`volta-website-dad`) **não roda no cluster**. Ele é publicado pela
Vercel, que se conecta direto ao repositório do Website no GitHub. Por isso, a
configuração fica no painel da Vercel e não neste repositório. Este documento
registra como ela foi feita.

O motivo da escolha está em
[`01-arquitetura-cicd.md`, seção 8](01-arquitetura-cicd.md#8-website-na-vercel).
O Dockerfile do Website existe só para o Docker Compose local.

## Como o deploy funciona

| Evento | Resultado |
|---|---|
| Abrir um PR | A Vercel gera um *preview* só daquele PR |
| Merge em `develop` | Preview estável, que usa a API de **QA** |
| Merge em `main` | **Produção**, que usa a API de produção |

Como o GitHub bloqueia o merge quando o CI falha, nada chega a `main` sem passar
pelos testes.

## Configuração do projeto

O projeto foi importado do GitHub pelo app da Vercel. Stack: React + TypeScript
com Vite.

| Campo | Valor |
|---|---|
| Framework | Vite |
| Install Command | `npm ci` |
| Build Command | `npm run build` (executa `tsc -b && vite build`) |
| Output Directory | `dist` |
| Production Branch | `main` |
| Outras branches e PRs | Preview |

## Variáveis de ambiente

No Vite, só variáveis que começam com `VITE_` chegam ao navegador. Elas são
**gravadas no código no momento do build**.

> **Nunca coloque segredo em uma variável `VITE_*`.** Qualquer pessoa consegue
> ler o valor no JavaScript do site.

Os valores de produção vêm do `.env.production` do repositório do Website; o
`.env.example` documenta todas as variáveis.

| Variável | Valor | Para quê |
|---|---|---|
| `VITE_API_BASE_URL` | `/api` | API principal |
| `VITE_CHAT_API_BASE_URL` | `/chat-api` | Chatbot |
| `VITE_RANKING_API_BASE_URL` | `/ranking-api` | Ranking (`api-redis`) |
| `VITE_USAR_MOCKS` | `false` | Usa as APIs reais em vez dos mocks |
| `VITE_CLOUDINARY_CLOUD_NAME` | conta do Cloudinary | Envio das fotos das ocorrências (não é segredo) |
| `VITE_CLOUDINARY_PRESET_OCORRENCIA` | preset sem assinatura | Idem |

## Como o navegador chega ao backend

O navegador chama caminhos relativos (`/api`, `/chat-api`, `/ranking-api`) e o
`vercel.json` do Website os repassa por *rewrite* ao backend no cluster. Assim o
site, em HTTPS, não fala direto com endereços HTTP e não há problema de CORS.

| Prefixo | Destino |
|---|---|
| `/api/*` | `api` (`https://api.qa.<SSH_HOST>.sslip.io`) |
| `/chat-api/*` | `chatbot` (`https://chat.qa.<SSH_HOST>.sslip.io`) |
| `/ranking-api/*` | `api-redis` (`https://ranking.qa.<SSH_HOST>.sslip.io`) |

> O `vercel.json` hoje aponta para o backend de **QA** em todos os deployments,
> inclusive em `main`. Para a produção usar o backend de produção, é preciso
> ajustar os destinos (por exemplo, trocar o arquivo na promoção para `main`).

> **Se o Elastic IP mudar** (por exemplo, ao recriar o cluster do zero), troque o
> IP nos destinos do `vercel.json` e faça um novo deploy.

As fotos não passam pelo cluster: o navegador envia direto ao Cloudinary e a
`api` guarda só a URL.

## Voltar uma versão

A Vercel guarda todos os deployments. No painel, abra o deployment antigo e
escolha **Promote to Production**.

## Por que não há workflow aqui

API e Chatbot precisam gerar imagem Docker e fazer deploy por SSH. O Website
não: a Vercel compila, publica e gera os previews sozinha. A verificação de
qualidade (lint, tipos, build) fica no CI do repositório do Website.

## Limite do plano

O plano Hobby da Vercel é para uso não comercial. Um projeto acadêmico se
enquadra.
