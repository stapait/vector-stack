#!/bin/bash
# Sobe o "EC2 local" (Amazon Linux 2023 + systemd + sshd em container) e
# roda a automação Ansible (vector-provision.yml) contra ele — um jeito de
# testar a automação de ponta a ponta sem precisar de uma conta AWS.
#
# Uso:
#   ./test.sh            # sobe o container (se preciso) e roda a playbook
#   ./test.sh --down      # derruba o container e o volume (limpa o "EBS" simulado)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANSIBLE_DIR="$SCRIPT_DIR/../../ansible"

if [ "${1:-}" = "--down" ]; then
  docker compose -f "$SCRIPT_DIR/docker-compose.yml" down -v
  exit 0
fi

"$SCRIPT_DIR/generate-ssh-key.sh"

echo "==> Subindo o container (Amazon Linux 2023 + systemd + sshd)..."
docker compose -f "$SCRIPT_DIR/docker-compose.yml" up -d --build

echo "==> Esperando o sshd aceitar conexão em 127.0.0.1:2222..."
for _ in $(seq 1 30); do
  if ssh -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=2 -o BatchMode=yes \
      -i "$SCRIPT_DIR/ssh/id_ed25519" -p 2222 ec2-user@127.0.0.1 true 2>/dev/null; then
    echo "    sshd pronto."
    break
  fi
  sleep 1
done

echo "==> Instalando collections do Galaxy declaradas em requirements.yml (hoje: nenhuma)..."
ansible-galaxy collection install -r "$ANSIBLE_DIR/requirements.yml"

echo "==> Rodando vector-provision.yml contra o EC2 local..."
(
  cd "$ANSIBLE_DIR"
  ansible-playbook -i inventory/local-ec2.ini vector-provision.yml -e @vars/vector.yml
)

echo
echo "Pronto. Pra investigar o resultado:"
echo "  ssh -i $SCRIPT_DIR/ssh/id_ed25519 -p 2222 ec2-user@127.0.0.1"
echo "Pra derrubar tudo:"
echo "  $0 --down"
