#!/usr/bin/env bash
#
# Atualiza a credencial da sessão do AWS Academy Learner Lab em um só passo:
# cola o bloco de "AWS Details" -> "AWS CLI" e o script grava em
# ~/.aws/credentials e, se pedido, também nos GitHub Secrets usados pelo
# ec2-power.yaml (AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_SESSION_TOKEN).
#
# A sessão do Learner Lab expira a cada ~4h — isso é uma limitação do próprio
# AWS Academy (token STS de curta duração) e nenhuma ferramenta contorna isso.
# Este script só evita editar o arquivo e recolar os secrets na mão toda vez.
#
# Uso:
#   ./scripts/update-aws-session.sh                    # lê o bloco colado via stdin (Ctrl+D pra terminar)
#   ./scripts/update-aws-session.sh credenciais.txt     # lê de um arquivo
#   ./scripts/update-aws-session.sh --gh                # também atualiza os GitHub Secrets do repo atual
#   ./scripts/update-aws-session.sh --gh --repo app-volta/volta-devops
#
# Formato esperado (exatamente o que a AWS mostra em "AWS Details" -> "AWS CLI"):
#   [default]
#   aws_access_key_id=...
#   aws_secret_access_key=...
#   aws_session_token=...

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-aws.sh
source "${SCRIPT_DIR}/lib-aws.sh"

UPDATE_GH=false
REPO=""
INPUT_FILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --gh) UPDATE_GH=true; shift ;;
    --repo) REPO="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) INPUT_FILE="$1"; shift ;;
  esac
done

if [ -n "$INPUT_FILE" ]; then
  [ -f "$INPUT_FILE" ] || die "arquivo '${INPUT_FILE}' não encontrado."
  BLOCK="$(cat "$INPUT_FILE")"
else
  log "Cole o bloco de 'AWS Details' -> 'AWS CLI' e finalize com Ctrl+D:"
  BLOCK="$(cat)"
fi

extract() {
  printf '%s\n' "$BLOCK" | tr -d '\r' | sed -n "s/^$1=//p" | head -1
}

ACCESS_KEY="$(extract aws_access_key_id)"
SECRET_KEY="$(extract aws_secret_access_key)"
SESSION_TOKEN="$(extract aws_session_token)"

[ -n "$ACCESS_KEY" ]    || die "aws_access_key_id não encontrado no bloco colado."
[ -n "$SECRET_KEY" ]    || die "aws_secret_access_key não encontrado no bloco colado."
[ -n "$SESSION_TOKEN" ] || die "aws_session_token não encontrado no bloco colado."

log "Gravando ~/.aws/credentials"
mkdir -p "${HOME}/.aws"
{
  echo "[default]"
  echo "aws_access_key_id=${ACCESS_KEY}"
  echo "aws_secret_access_key=${SECRET_KEY}"
  echo "aws_session_token=${SESSION_TOKEN}"
  echo "region=${AWS_REGION}"
} > "${HOME}/.aws/credentials"
chmod 600 "${HOME}/.aws/credentials"
ok "credenciais gravadas em ${HOME}/.aws/credentials"

log "Validando com a AWS"
if ! aws sts get-caller-identity >/dev/null 2>&1; then
  die "AWS recusou as credenciais coladas — confira se copiou o bloco certo do Learner Lab."
fi
ok "sessão válida (conta $(aws_account_id))"

if [ "$UPDATE_GH" = true ]; then
  command -v gh >/dev/null 2>&1 || die "GitHub CLI (gh) não encontrado — instale para usar --gh."
  gh auth status >/dev/null 2>&1 || die "gh não está autenticado. Rode 'gh auth login' primeiro."

  log "Atualizando GitHub Secrets${REPO:+ em ${REPO}}"
  if [ -n "$REPO" ]; then
    gh secret set AWS_ACCESS_KEY_ID     --repo "$REPO" --body "$ACCESS_KEY"
    gh secret set AWS_SECRET_ACCESS_KEY --repo "$REPO" --body "$SECRET_KEY"
    gh secret set AWS_SESSION_TOKEN     --repo "$REPO" --body "$SESSION_TOKEN"
  else
    gh secret set AWS_ACCESS_KEY_ID     --body "$ACCESS_KEY"
    gh secret set AWS_SECRET_ACCESS_KEY --body "$SECRET_KEY"
    gh secret set AWS_SESSION_TOKEN     --body "$SESSION_TOKEN"
  fi
  ok "secrets atualizados"
fi
