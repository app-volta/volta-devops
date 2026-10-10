# Vercel: Website

O Website (`volta-website-dad`) **não roda no cluster**. Ele é publicado pela
Vercel, que se conecta direto ao repositório do Website no GitHub. Por isso, a
configuração fica no painel da Vercel e não neste repositório. Este documento
registra como ela foi feita.

O motivo da escolha está em
[`01-arquitetura-cicd.md`, seção 2.3](01-arquitetura-cicd.md#23-website-na-vercel-sem-docker-em-produção).
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

No Vite, só variáveis que começam com `VITE_` chegam ao navegador (por exemplo
`import.meta.env.VITE_API_URL`). Elas são **gravadas no código no momento do
build**.

> **Nunca coloque segredo em uma variável `VITE_*`.** Qualquer pessoa consegue
> ler o valor no JavaScript do site.

Os endereços do backend seguem o padrão usado pelo
[`dispatch-deploy.yaml`](../.github/workflows/dispatch-deploy.yaml), baseado no
Elastic IP do cluster (`SSH_HOST`):

| Ambiente na Vercel | API | Ranking | Chatbot |
|---|---|---|---|
| Preview (QA) | `https://api.qa.<SSH_HOST>.sslip.io` | `https://ranking.qa.<SSH_HOST>.sslip.io` | `https://chat.qa.<SSH_HOST>.sslip.io` |
| Production | `http://api.<SSH_HOST>.sslip.io` | `http://ranking.<SSH_HOST>.sslip.io` | `http://chat.<SSH_HOST>.sslip.io` |

Cadastre em **Settings → Environment Variables**, com o nome que o código do
Website usa (`VITE_API_URL` e equivalentes).

> **Se o Elastic IP mudar** (por exemplo, ao recriar o cluster do zero), atualize
> essas variáveis na Vercel e faça um novo deploy. Como o valor é gravado no
> build, só mudar a variável não basta.

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
