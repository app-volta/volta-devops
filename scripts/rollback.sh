#!/usr/bin/env bash
#
# Rollback de emergência: volta um serviço para uma versão anterior.
#
# Existe como script local de propósito. Rollback acontece quando algo já deu
# errado — é justamente a hora em que você não quer depender de o GitHub estar
# no ar, nem esperar uma pipeline de dois minutos.
#
# Uso:
#   ./scripts/rollback.sh <ambiente> <serviço> [tag]
#
#   ./scripts/rollback.sh prod api                 # volta uma revisão
#   ./scripts/rollback.sh prod api prod-a1b2c3d    # volta para uma tag exata
#   ./scripts/rollback.sh prod api --history       # lista as revisões
#
# ATENÇÃO — o rollback altera o cluster sem passar pelo Git. Depois de estancar
# o problema, reimplante a tag boa pela pipeline (workflow "Deploy" -> Run
# workflow) para o repositório voltar a refletir o que está rodando.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-aws.sh
source "${SCRIPT_DIR}/lib-aws.sh"

KEY_FILE="${KEY_FILE:-${HOME}/.ssh/${KEY_NAME}.pem}"

usage() {
  cat <<'USAGE'
Uso: ./scripts/rollback.sh <ambiente> <serviço> [tag|--history]

  ambiente   qa | prod
  serviço    api | chatbot
  tag        Tag imutável a restaurar (ex.: prod-a1b2c3d).
             Omitida, volta para a revisão imediatamente anterior.
  --history  Apenas lista o histórico de revisões, sem alterar nada.

Exemplos:
  ./scripts/rollback.sh prod api
  ./scripts/rollback.sh prod api prod-a1b2c3d
  ./scripts/rollback.sh qa chatbot --history
USAGE
}

# --- Argumentos --------------------------------------------------------------
ENVIRONMENT="${1:-}"
SERVICE="${2:-}"
TARGET="${3:-}"

if [ -z "$ENVIRONMENT" ] || [ -z "$SERVICE" ]; then
  usage
  exit 1
fi

case "$ENVIRONMENT" in
  qa|prod) ;;
  *) die "Ambiente inválido: '${ENVIRONMENT}'. Use 'qa' ou 'prod'." ;;
esac

case "$SERVICE" in
  api|chatbot) ;;
  *) die "Serviço inválido: '${SERVICE}'. Use 'api' ou 'chatbot'." ;;
esac

NAMESPACE="volta-${ENVIRONMENT}"

# --- Conexão com o cluster ---------------------------------------------------
require_aws

INSTANCE_ID=$(find_instance_id)
[ -n "$INSTANCE_ID" ] || die "Instância '${INSTANCE_NAME}' não encontrada."

STATE=$(instance_state "$INSTANCE_ID")
[ "$STATE" = "running" ] || die "A instância está '${STATE}'. Ligue-a antes (workflow 'Ligar e desligar o cluster')."

HOST=$(instance_ip "$INSTANCE_ID")
[ -n "$HOST" ] || die "Instância sem IP público. O Elastic IP está associado?"

[ -f "$KEY_FILE" ] || die "Chave SSH não encontrada em ${KEY_FILE}."

# Executa um comando kubectl na instância.
remote() {
  ssh -i "$KEY_FILE" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
    "ec2-user@${HOST}" "$@"
}

remote 'true' 2>/dev/null || die "Não foi possível conectar em ${HOST} por SSH."

# --- Histórico ---------------------------------------------------------------
log "Histórico de ${SERVICE} em ${NAMESPACE}"
remote "kubectl -n ${NAMESPACE} rollout history deployment/${SERVICE}"

CURRENT=$(remote "kubectl -n ${NAMESPACE} get deployment/${SERVICE} \
  -o jsonpath='{.spec.template.spec.containers[0].image}'")
ok "imagem atual: ${CURRENT}"

if [ "$TARGET" = "--history" ]; then
  exit 0
fi

# --- Confirmação -------------------------------------------------------------
if [ -n "$TARGET" ]; then
  # Impede restaurar uma imagem de QA em produção (e vice-versa).
  if [ "${TARGET%%-*}" != "$ENVIRONMENT" ]; then
    die "A tag '${TARGET}' não pertence ao ambiente '${ENVIRONMENT}'."
  fi

  IMAGE="${CURRENT%:*}:${TARGET}"
  ACTION="restaurar a imagem ${IMAGE}"
else
  ACTION="voltar para a revisão anterior"
fi

warn "Prestes a ${ACTION} em ${NAMESPACE}."
printf '  Confirma? [s/N] '
read -r ANSWER
case "$ANSWER" in
  s|S|sim|SIM) ;;
  *) echo "Cancelado."; exit 0 ;;
esac

# --- Rollback ----------------------------------------------------------------
if [ -n "$TARGET" ]; then
  log "Restaurando ${IMAGE}"
  remote "kubectl -n ${NAMESPACE} set image deployment/${SERVICE} ${SERVICE}=${IMAGE}"
else
  log "Voltando uma revisão"
  remote "kubectl -n ${NAMESPACE} rollout undo deployment/${SERVICE}"
fi

log "Aguardando o rollout"
if remote "kubectl -n ${NAMESPACE} rollout status deployment/${SERVICE} --timeout=180s"; then
  ok "rollback concluído"
else
  warn "O rollout não concluiu no tempo esperado. Investigue com:"
  warn "  ssh -i ${KEY_FILE} ec2-user@${HOST} 'kubectl -n ${NAMESPACE} describe deployment/${SERVICE}'"
  exit 1
fi

FINAL=$(remote "kubectl -n ${NAMESPACE} get deployment/${SERVICE} \
  -o jsonpath='{.spec.template.spec.containers[0].image}'")

cat <<SUMMARY

--------------------------------------------------------------
  Rollback aplicado
--------------------------------------------------------------
  Serviço     ${SERVICE}
  Namespace   ${NAMESPACE}
  Antes       ${CURRENT}
  Agora       ${FINAL}

  O cluster agora DIVERGE do Git. Para reconciliar, reimplante
  esta mesma tag pela pipeline:
    GitHub -> Actions -> "Deploy" -> Run workflow
      service: ${SERVICE}
      environment: ${ENVIRONMENT}
      image-tag: ${FINAL##*:}
--------------------------------------------------------------

SUMMARY
