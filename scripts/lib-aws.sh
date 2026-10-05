#!/usr/bin/env bash
# Funções e convenções compartilhadas pelos scripts de infraestrutura AWS.
# Não executar diretamente: use `source scripts/lib-aws.sh`.

set -euo pipefail

# --- Convenções do projeto ---------------------------------------------------
export AWS_REGION="${AWS_REGION:-us-east-1}"

PROJECT_TAG="${PROJECT_TAG:-volta}"
INSTANCE_NAME="${INSTANCE_NAME:-volta-k3s}"
SG_NAME="${SG_NAME:-volta-k3s-sg}"
KEY_NAME="${KEY_NAME:-volta-k3s}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.medium}"
VOLUME_SIZE_GB="${VOLUME_SIZE_GB:-30}"

# O Learner Lab já fornece estes recursos prontos; não temos permissão de criar
# roles ou instance profiles próprios.
INSTANCE_PROFILE="${INSTANCE_PROFILE:-LabInstanceProfile}"

# CIDR autorizado no SSH. O deploy roda a partir de runners do GitHub Actions,
# cujos IPs são dinâmicos — daí o default aberto. Restrinja se for fazer deploy
# só da sua máquina.
SSH_CIDR="${SSH_CIDR:-0.0.0.0/0}"

# Auto-stop por inatividade
IDLE_MINUTES="${IDLE_MINUTES:-15}"
IDLE_BYTES_THRESHOLD="${IDLE_BYTES_THRESHOLD:-1000000}"  # 1 MB por período de 5 min

# --- Utilidades --------------------------------------------------------------
log()  { printf '\033[0;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[0;32m  ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m  !\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[0;31merro:\033[0m %s\n' "$*" >&2; exit 1; }

require_aws() {
  command -v aws >/dev/null 2>&1 || die "AWS CLI não encontrado. Instale a v2."

  if ! aws sts get-caller-identity >/dev/null 2>&1; then
    die "Credenciais AWS inválidas ou expiradas.
     No Learner Lab elas duram 4 horas: abra 'AWS Details' → 'AWS CLI' e
     recole o bloco em ~/.aws/credentials."
  fi
}

aws_account_id() {
  aws sts get-caller-identity --query Account --output text
}

# Id da instância do projeto, se existir (ignora instâncias já encerradas).
find_instance_id() {
  aws ec2 describe-instances \
    --region "$AWS_REGION" \
    --filters "Name=tag:Name,Values=${INSTANCE_NAME}" \
              "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[].Instances[0].InstanceId' \
    --output text 2>/dev/null | grep -v '^None$' | head -1 || true
}

instance_state() {
  aws ec2 describe-instances \
    --region "$AWS_REGION" --instance-ids "$1" \
    --query 'Reservations[0].Instances[0].State.Name' --output text
}

# IP público atual da instância (o Elastic IP, quando associado).
instance_ip() {
  aws ec2 describe-instances \
    --region "$AWS_REGION" --instance-ids "$1" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text 2>/dev/null \
    | grep -v '^None$' || true
}

# Elastic IP do projeto, se já alocado.
find_elastic_ip() {
  aws ec2 describe-addresses \
    --region "$AWS_REGION" \
    --filters "Name=tag:Name,Values=${INSTANCE_NAME}-eip" \
    --query 'Addresses[0].PublicIp' --output text 2>/dev/null \
    | grep -v '^None$' || true
}
