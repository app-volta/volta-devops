#!/usr/bin/env bash
# User data da EC2: instala e configura o k3s no primeiro boot.
# Executado como root pelo cloud-init. Log em /var/log/cloud-init-output.log.

set -euxo pipefail

# --- Pacotes básicos ---------------------------------------------------------
dnf install -y curl tar git jq

# --- k3s ---------------------------------------------------------------------
# --write-kubeconfig-mode 644 permite que o usuário ec2-user use kubectl sem
# sudo, que é o que o deploy por SSH precisa.
# O Traefik fica habilitado de propósito: é o ingress da arquitetura.
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server \
  --write-kubeconfig-mode 644 \
  --disable=metrics-server \
  --node-name=volta-k3s" sh -

systemctl enable --now k3s

# Espera o cluster responder antes de aplicar qualquer coisa.
for _ in $(seq 1 60); do
  if k3s kubectl get nodes >/dev/null 2>&1; then break; fi
  sleep 5
done

# --- kubectl e kustomize para o ec2-user -------------------------------------
ln -sf /usr/local/bin/k3s /usr/local/bin/kubectl || true
cat >/etc/profile.d/k3s.sh <<'PROFILE'
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
PROFILE
chmod 644 /etc/profile.d/k3s.sh

curl -sfL https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh \
  | bash -s -- 5.4.3 /usr/local/bin

# --- Namespaces do projeto ---------------------------------------------------
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
k3s kubectl apply -f - <<'NAMESPACES'
apiVersion: v1
kind: Namespace
metadata:
  name: volta-qa
  labels:
    app.kubernetes.io/part-of: volta
    environment: qa
---
apiVersion: v1
kind: Namespace
metadata:
  name: volta-prod
  labels:
    app.kubernetes.io/part-of: volta
    environment: prod
NAMESPACES

# --- Diretório de trabalho do deploy -----------------------------------------
install -d -o ec2-user -g ec2-user /home/ec2-user/volta-devops

echo "k3s pronto."
k3s kubectl get nodes
