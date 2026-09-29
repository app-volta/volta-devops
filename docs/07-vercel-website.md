# Vercel — Website

O Website (`volta-website-dad`) é conteinerizado apenas para o Compose local;
em produção **não roda no cluster** (ver [`01-arquitetura-cicd.md`, seção 2.3](01-arquitetura-cicd.md#23-website-na-vercel-sem-docker-em-produção)).
O deploy é feito pela **integração nativa Vercel↔GitHub**, direto no
repositório do Website — este doc registra como esse projeto está
provisionado na Vercel, já que a configuração em si não mora neste
repositório.

## Provisionamento

Projeto importado direto do repositório GitHub do Website via GitHub App da
Vercel. Stack: React + TypeScript com Vite.

| Campo | Valor |
|---|---|
| Framework detectado | Vite |
| Install Command | `npm ci` (repo tem `package-lock.json`) |
| Build Command | `npm run build` → `tsc -b && vite build` |
| Output Directory | `dist` |
| Branches | `main` → Production · demais branches/PRs → Preview |

## Variáveis de ambiente

Por ser Vite, só variáveis com prefixo `VITE_` são embutidas no bundle (ex.:
`import.meta.env.VITE_API_URL`). Os hosts do backend seguem o padrão definido
no dispatch de deploy
([`.github/workflows/dispatch-deploy.yaml`](../.github/workflows/dispatch-deploy.yaml)),
baseado no IP do cluster (`vars.SSH_HOST`) e no ambiente:

| Ambiente Vercel | API | Ranking (api-redis) | Chatbot |
|---|---|---|---|
| Preview (QA) | `http://api.qa.<SSH_HOST>.sslip.io` | `http://ranking.qa.<SSH_HOST>.sslip.io` | `http://chat.qa.<SSH_HOST>.sslip.io` |
| Production | `http://api.<SSH_HOST>.sslip.io` | `http://ranking.<SSH_HOST>.sslip.io` | `http://chat.<SSH_HOST>.sslip.io` |

Cadastradas em *Settings → Environment Variables* no projeto Vercel, com o
nome exato que o código do Website usa (`VITE_API_URL` e equivalentes).

## Por que não um workflow reutilizável aqui

Diferente de API/Chatbot (que dependem de build de imagem Docker e deploy via
SSH no k3s), o Website não precisa de nenhum passo de CI neste repositório: a
Vercel builda, testa preview por PR e publica em produção sozinha ao detectar
push.
