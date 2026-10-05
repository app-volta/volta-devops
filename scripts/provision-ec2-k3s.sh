#!/usr/bin/env bash
#
# Provisiona a infraestrutura do cluster no AWS Academy Learner Lab:
#   security group -> key pair -> instância EC2 com k3s -> Elastic IP -> auto-stop
#
# Idempotente: rodar de novo não duplica recurso, apenas reporta o que já existe.
#
# Uso:  ./scripts/provision-ec2-k3s.sh
#
# Pré-requisitos:
#   - AWS CLI v2 com as credenciais da sessão do Learner Lab (válidas por 4h)
#   - jq

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-aws.sh
source "${SCRIPT_DIR}/lib-aws.sh"

KEY_FILE="${KEY_FILE:-${HOME}/.ssh/${KEY_NAME}.pem}"

require_aws
log "Conta $(aws_account_id) / região ${AWS_REGION}"

# --- 1. Security group -------------------------------------------------------
log "Security group '${SG_NAME}'"

SG_ID=$(aws ec2 describe-security-groups \
  --region "$AWS_REGION" \
  --filters "Name=group-name,Values=${SG_NAME}" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null | grep -v '^None$' || true)

if [ -z "$SG_ID" ]; then
  VPC_ID=$(aws ec2 describe-vpcs --region "$AWS_REGION" \
    --filters "Name=isDefault,Values=true" \
    --query 'Vpcs[0].VpcId' --output text)
  [ "$VPC_ID" != "None" ] || die "VPC padrão não encontrada na região ${AWS_REGION}."

  SG_ID=$(aws ec2 create-security-group \
    --region "$AWS_REGION" \
    --group-name "$SG_NAME" \
    --description "Cluster k3s do projeto Volta" \
    --vpc-id "$VPC_ID" \
    --query 'GroupId' --output text)
  ok "criado: ${SG_ID}"
else
  ok "já existe: ${SG_ID}"
fi

# Regras de entrada. A AWS devolve erro quando a regra já existe, daí o if.
authorize() {
  local port="$1" cidr="$2" desc="$3"
  if aws ec2 authorize-security-group-ingress \
      --region "$AWS_REGION" --group-id "$SG_ID" \
      --ip-permissions "IpProtocol=tcp,FromPort=${port},ToPort=${port},IpRanges=[{CidrIp=${cidr},Description=${desc}}]" \
      >/dev/null 2>&1; then
    ok "porta ${port} liberada para ${cidr}"
  else
    ok "porta ${port} já liberada"
  fi
}

authorize 22  "$SSH_CIDR"  "SSH-deploy"
authorize 80  "0.0.0.0/0"  "HTTP-Traefik"
authorize 443 "0.0.0.0/0"  "HTTPS-Traefik"

if [ "$SSH_CIDR" = "0.0.0.0/0" ]; then
  warn "SSH aberto para a internet: os runners do GitHub Actions têm IP dinâmico."
  warn "A autenticação é exclusivamente por chave; senha está desabilitada na AMI."
fi

# --- 2. Key pair -------------------------------------------------------------
log "Key pair '${KEY_NAME}'"

if aws ec2 describe-key-pairs --region "$AWS_REGION" --key-names "$KEY_NAME" >/dev/null 2>&1; then
  ok "já existe na AWS"
  if [ ! -f "$KEY_FILE" ]; then
    warn "chave privada ausente em ${KEY_FILE}"
    warn "a AWS não permite baixá-la de novo: apague o key pair e rode este script outra vez"
  fi
else
  mkdir -p "$(dirname "$KEY_FILE")"
  aws ec2 create-key-pair \
    --region "$AWS_REGION" --key-name "$KEY_NAME" \
    --query 'KeyMaterial' --output text > "$KEY_FILE"
  chmod 400 "$KEY_FILE"
  ok "criado; chave privada em ${KEY_FILE}"
  warn "guarde o conteúdo de ${KEY_FILE} no secret SSH_PRIVATE_KEY do repositório DevOps"
fi

# --- 3. Instância ------------------------------------------------------------
log "Instância '${INSTANCE_NAME}'"

INSTANCE_ID=$(find_instance_id)

if [ -z "$INSTANCE_ID" ]; then
  # AMI do Amazon Linux 2023 pelo SSM Parameter Store: sempre a mais recente.
  AMI_ID=$(aws ssm get-parameters \
    --region "$AWS_REGION" \
    --names /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
    --query 'Parameters[0].Value' --output text)
  ok "AMI: ${AMI_ID}"

  BDM="[{\"DeviceName\":\"/dev/xvda\",\"Ebs\":{\"VolumeSize\":${VOLUME_SIZE_GB},\"VolumeType\":\"gp3\",\"DeleteOnTermination\":true}}]"

  INSTANCE_ID=$(aws ec2 run-instances \
    --region "$AWS_REGION" \
    --image-id "$AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" \
    --security-group-ids "$SG_ID" \
    --iam-instance-profile "Name=${INSTANCE_PROFILE}" \
    --block-device-mappings "$BDM" \
    --metadata-options "HttpTokens=required,HttpEndpoint=enabled" \
    --user-data "file://${SCRIPT_DIR}/cloud-init-k3s.sh" \
    --tag-specifications \
      "ResourceType=instance,Tags=[{Key=Name,Value=${INSTANCE_NAME}},{Key=Project,Value=${PROJECT_TAG}}]" \
    --query 'Instances[0].InstanceId' --output text)
  ok "criada: ${INSTANCE_ID}"

  log "Aguardando a instância entrar em 'running'..."
  aws ec2 wait instance-running --region "$AWS_REGION" --instance-ids "$INSTANCE_ID"
  ok "running"
else
  ok "já existe: ${INSTANCE_ID} ($(instance_state "$INSTANCE_ID"))"
fi

# --- 4. Elastic IP -----------------------------------------------------------
# Obrigatório: o Learner Lab para as instâncias ao encerrar a sessão, e elas
# voltam com IP público novo. Sem EIP, o SSH do deploy e todos os hostnames
# sslip.io do ingress quebram a cada sessão.
log "Elastic IP"

EIP=$(find_elastic_ip)

if [ -z "$EIP" ]; then
  ALLOC_ID=$(aws ec2 allocate-address \
    --region "$AWS_REGION" --domain vpc \
    --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=${INSTANCE_NAME}-eip},{Key=Project,Value=${PROJECT_TAG}}]" \
    --query 'AllocationId' --output text)
  EIP=$(aws ec2 describe-addresses --region "$AWS_REGION" \
    --allocation-ids "$ALLOC_ID" --query 'Addresses[0].PublicIp' --output text)
  ok "alocado: ${EIP}"
else
  ALLOC_ID=$(aws ec2 describe-addresses --region "$AWS_REGION" \
    --public-ips "$EIP" --query 'Addresses[0].AllocationId' --output text)
  ok "já alocado: ${EIP}"
fi

ASSOC_INSTANCE=$(aws ec2 describe-addresses --region "$AWS_REGION" \
  --allocation-ids "$ALLOC_ID" --query 'Addresses[0].InstanceId' --output text 2>/dev/null | grep -v '^None$' || true)

if [ "$ASSOC_INSTANCE" != "$INSTANCE_ID" ]; then
  aws ec2 associate-address --region "$AWS_REGION" \
    --allocation-id "$ALLOC_ID" --instance-id "$INSTANCE_ID" >/dev/null
  ok "associado à instância"
else
  ok "já associado à instância"
fi

# --- 5. Auto-stop por inatividade -------------------------------------------
# Alarme do CloudWatch com ação nativa de stop do EC2. Não precisa de Lambda nem
# de role adicional, o que importa porque o Learner Lab não deixa criar IAM.
log "Alarme de auto-stop (${IDLE_MINUTES} min sem tráfego)"

PERIODS=$(( IDLE_MINUTES / 5 ))
[ "$PERIODS" -lt 1 ] && PERIODS=1

aws cloudwatch put-metric-alarm \
  --region "$AWS_REGION" \
  --alarm-name "${INSTANCE_NAME}-autostop" \
  --alarm-description "Para a instância apos ${IDLE_MINUTES} min sem trafego de rede" \
  --namespace AWS/EC2 \
  --metric-name NetworkIn \
  --dimensions "Name=InstanceId,Value=${INSTANCE_ID}" \
  --statistic Sum \
  --period 300 \
  --evaluation-periods "$PERIODS" \
  --threshold "$IDLE_BYTES_THRESHOLD" \
  --comparison-operator LessThanThreshold \
  --treat-missing-data breaching \
  --alarm-actions "arn:aws:automate:${AWS_REGION}:ec2:stop" >/dev/null

ok "alarme configurado"

# --- Resumo ------------------------------------------------------------------
STATE=$(instance_state "$INSTANCE_ID")

cat <<SUMMARY

--------------------------------------------------------------
  Cluster provisionado
--------------------------------------------------------------
  Instância      ${INSTANCE_ID} (${INSTANCE_TYPE})
  Estado         ${STATE}
  Elastic IP     ${EIP}
  Security group ${SG_ID}
  Chave SSH      ${KEY_FILE}
  Auto-stop      ${IDLE_MINUTES} min sem tráfego

  SSH
    ssh -i ${KEY_FILE} ec2-user@${EIP}

  Hostnames do ingress
    api.qa.${EIP}.sslip.io     chat.qa.${EIP}.sslip.io
    api.${EIP}.sslip.io        chat.${EIP}.sslip.io

  Próximos passos
    1. Secret SSH_PRIVATE_KEY no repositório DevOps = conteúdo de ${KEY_FILE}
    2. Variable SSH_HOST nos Environments qa e prod = ${EIP}
    3. O k3s leva ~3 min para ficar pronto no primeiro boot. Verifique com:
         ssh -i ${KEY_FILE} ec2-user@${EIP} 'kubectl get nodes'
--------------------------------------------------------------

SUMMARY
