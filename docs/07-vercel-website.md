# Vercel — Website

O Website é conteinerizado apenas para o Compose local; em produção **não roda
no cluster** (ver [`01-arquitetura-cicd.md`, seção 2.3](01-arquitetura-cicd.md#23-website-na-vercel-sem-docker-em-produção)).
O deploy é feito pela **integração nativa Vercel↔GitHub**, direto no
repositório do Website — este doc existe só como referência rápida de como
esse projeto está configurado, já que a configuração em si não mora neste
repositório.

## Configuração no dashboard da Vercel

1. **Add New Project** → importar o repositório do Website (GitHub App da
   Vercel precisa de acesso a esse repo na organização).
2. **Branches**:
   - `main` → produção.
   - `develop` (e qualquer outra branch/PR) → preview automático.
3. **Build settings**: detectado automaticamente pelo framework do Website;
   ajustar apenas se o projeto não estiver na raiz do repositório.

## Variáveis de ambiente

Os hosts do backend seguem o padrão definido no dispatch de deploy
([`.github/workflows/dispatch-deploy.yaml`](../.github/workflows/dispatch-deploy.yaml)),
baseado no IP do cluster (`vars.SSH_HOST`) e no ambiente:

| Ambiente | API | Ranking (api-redis) | Chatbot |
|---|---|---|---|
| QA | `http://api.qa.<SSH_HOST>.sslip.io` | `http://ranking.qa.<SSH_HOST>.sslip.io` | `http://chat.qa.<SSH_HOST>.sslip.io` |
| PROD | `http://api.<SSH_HOST>.sslip.io` | `http://ranking.<SSH_HOST>.sslip.io` | `http://chat.<SSH_HOST>.sslip.io` |

Configurar essas URLs como env vars por ambiente no dashboard da Vercel
(*Settings → Environment Variables*, com escopo Production/Preview), com o
nome que o Website espera (ex.: `NEXT_PUBLIC_API_URL`) — o valor exato precisa
ser conferido no repositório do Website.

## Por que não um workflow reutilizável aqui

Diferente de API/Chatbot (que dependem de build de imagem Docker e deploy via
SSH no k3s), o Website não precisa de nenhum passo de CI neste repositório: a
Vercel já builda, testa preview por PR e publica em produção sozinha ao
detectar push. Um workflow próprio rodando `vercel deploy` via CLI só faria
sentido se algum dia for necessário orquestrar o deploy do site junto com o
resto da esteira (por exemplo, aguardar smoke test do backend antes de
promover o Website) — não é o caso hoje.
