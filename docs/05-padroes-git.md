# Padrões de Git

Regras para branches, commits e Pull Requests. Muitas delas são verificadas
automaticamente pelo workflow `validate-pr`: se você fugir do padrão, o PR
fica bloqueado.

## Branches

Existem duas branches permanentes:

| Branch | Representa | Deploy |
|---|---|---|
| `develop` | Integração e QA | Automático para QA |
| `main` | Produção | Automático para produção, com aprovação manual |

Todo o trabalho acontece em branches curtas criadas a partir de `develop`.

### Nome da branch

```text
<tipo>/SCRUM-<número>
```

| Tipo | Quando usar |
|---|---|
| `feat` | Funcionalidade nova |
| `fix` | Correção de bug |
| `refactor` | Mudança de código sem mudar o comportamento |
| `chore` | Tarefas de manutenção (dependências, configs) |
| `test` | Testes |
| `docs` | Documentação |

O número é o do ticket no Jira, com 1 a 4 dígitos. O prefixo é sempre `SCRUM`
em maiúsculas.

| Exemplo | Válido? |
|---|---|
| `feat/SCRUM-1858` | Sim |
| `fix/SCRUM-123` | Sim |
| `feat/scrum-1858` | Não (minúsculas) |
| `feat/SCRU-1858` | Não (prefixo errado) |
| `feat/SCRUM-1858-login` | Não (sem descrição no nome) |

Padrão técnico (regex): `^(feat|fix|refactor|chore|test|docs)/SCRUM-[0-9]{1,4}$`

## Passo a passo de uma tarefa

```bash
git switch develop
git pull
git switch -c feat/SCRUM-1858

# ...trabalhe e faça commits...

git push -u origin feat/SCRUM-1858
```

Depois, abra um Pull Request para `develop`.

## Commits e título do PR

Usamos o padrão **Conventional Commits**:

```text
<tipo>(escopo opcional): descrição curta
```

Exemplos:

```text
feat: adiciona endpoint de login
fix(deploy): preserva imagens existentes no deploy individual
docs: reescreve o runbook de deploy
```

O que importa mais é o **título do PR**: como usamos *squash merge*, o título
vira a mensagem do commit em `develop`. O workflow rejeita títulos fora do
padrão.

## Pull Requests

| Origem → Destino | Permitido? | Tipo de merge |
|---|---|---|
| `feat/...`, `fix/...` etc. → `develop` | Sim | **Squash** |
| `develop` → `main` | Sim | **Merge commit** (nunca squash) |
| `fix/...` (criada a partir de `main`) → `main` | Sim (hotfix) | Squash |
| Qualquer outra → `main` | Não | — |
| Push direto em `develop` ou `main` | Não | — |

Antes do merge, o PR precisa de:

- os checks `validate-pr` e `build-test` verdes;
- 1 aprovação de outra pessoa;
- todas as conversas resolvidas.

Para `main`, também é exigida a aprovação de um CODEOWNER e a branch precisa
estar atualizada.

Boas práticas:

- **Um PR, um ticket.** PRs que resolvem várias coisas são difíceis de revisar.
- Cite o ticket (`SCRUM-1858`) na descrição.
- Descreva o que mudou e como testar.

### Por que nunca fazer squash de `develop` para `main`?

O squash cria um commit novo em `main` que o Git não reconhece como "o mesmo"
que os commits de `develop`. No próximo PR, o Git acha que as branches
divergiram e traz conflitos repetidos. Com merge commit o histórico fica
alinhado.

## Hotfix (produção quebrou)

Quando a produção quebra e `develop` já tem trabalho que ainda não foi validado:

1. Crie `fix/SCRUM-123` **a partir de `main`**.
2. Abra o PR para `main` e passe pelos mesmos checks e aprovação.
3. Depois do merge, **abra imediatamente um PR de `main` para `develop`**.

O passo 3 é obrigatório. Sem ele, o próximo `develop → main` traz o bug de
volta.

## Validar o que o `validate-pr` confere

O workflow [`reusable-validate-pr.yaml`](../.github/workflows/reusable-validate-pr.yaml)
roda em todo PR e checa três coisas:

1. O nome da branch segue o padrão acima (a branch `develop` é exceção).
2. A branch de destino é permitida (tabela de PRs acima).
3. O título segue o Conventional Commits.

Para usá-lo em outro repositório, veja o exemplo no [`README.md`](../README.md).
