#!/bin/bash
# Sobe a VM Vagrant (Amazon Linux 2023 + VirtualBox) e roda a automação
# Ansible (vector-provision.yml) contra ela — igual ao
# docker/local-ec2/test.sh, mas numa VM de verdade em vez de container.
#
# Uso:
#   ./test.sh            # sobe a VM (se preciso) e roda a playbook
#   ./test.sh --down      # destrói a VM (equivalente a "reseta a EC2 e o EBS")
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANSIBLE_DIR="$SCRIPT_DIR/../ansible"

if [ "${1:-}" = "--down" ]; then
  (cd "$SCRIPT_DIR" && vagrant destroy -f)
  exit 0
fi

echo "==> Subindo a VM (bento/amazonlinux-2023 via VirtualBox)..."
(cd "$SCRIPT_DIR" && vagrant up)

echo "==> Instalando collections do Galaxy declaradas em requirements.yml (hoje: nenhuma)..."
ansible-galaxy collection install -r "$ANSIBLE_DIR/requirements.yml"

echo "==> Rodando vector-provision.yml contra a VM Vagrant..."
(
  cd "$ANSIBLE_DIR"
  ansible-playbook -i inventory/vagrant.ini vector-provision.yml
)

echo
echo "Pronto. Pra investigar o resultado:"
echo "  cd $SCRIPT_DIR && vagrant ssh"
echo "Pra destruir a VM:"
echo "  $0 --down"
