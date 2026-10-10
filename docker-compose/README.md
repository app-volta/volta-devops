# Docker Compose (ambiente local)

Sobe o backend do Volta localmente, sem precisar instalar Java, Python,
Postgres ou MongoDB.

## O que sobe

| Serviço | Porta | Descrição |
|---|---|---|
| `postgres` | 5432 | Banco relacional (PostgreSQL 16) |
| `mongo` | 27017 | Memória das conversas do chatbot (MongoDB 7) |
| `api` | 8080 | API principal (Spring Boot) |
| `chatbot` | 8000 | Chatbot (FastAPI), com `ENVIRONMENT=qa` |

O Website e o Mobile **não** estão aqui. Rode o Website com `npm run dev` e o
Mobile pelo Android Studio.

## Antes de começar

1. Instale o [Docker](https://docs.docker.com/get-docker/).
2. Clone os repositórios **lado a lado**, porque o Compose usa caminhos
   relativos:

   ```text
   volta/
   ├── volta-api/
   ├── volta-chatbot/
   └── volta-devops/     ← rode os comandos daqui
   ```

3. Crie o arquivo `.env` a partir do exemplo e preencha:

   ```bash
   cd volta-devops/docker-compose
   cp .env.example .env
   ```

   Os campos mais importantes: `JWT_KEY`, `JWT_EXPIRATION`, `GEMINI_API_KEY` e
   `GROQ_API_KEY`. O arquivo `.env` **nunca** deve ser commitado.

## Comandos

```bash
docker compose up -d --build        # sobe tudo
docker compose ps                   # vê o estado e se estão saudáveis
docker compose logs -f api          # acompanha os logs da API
docker compose down                 # para tudo (mantém os dados)
docker compose down -v              # para tudo e APAGA os bancos locais
```

Subir só os bancos (útil se você roda a API pela IDE):

```bash
docker compose up -d postgres mongo
```

## Conferir se funcionou

```bash
curl http://localhost:8080/actuator/health   # API
curl http://localhost:8000/health            # Chatbot
```

## Problemas comuns

| Sintoma | O que fazer |
|---|---|
| `path ../../volta-api not found` | Os repositórios não estão lado a lado (veja acima) |
| API demora a ficar saudável | Normal: pode levar até 1 minuto no primeiro start |
| Porta já em uso | Pare o que estiver usando 5432, 8080, 8000 ou 27017 |
| Quero recomeçar do zero | `docker compose down -v` e suba de novo |

As senhas locais (`volta_local`) servem só para desenvolvimento. Não as use em
QA nem em produção.
