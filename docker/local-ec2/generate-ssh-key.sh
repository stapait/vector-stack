#!/bin/bash
# Gera um par de chaves SSH efêmero só pra este container de teste local
# (não é a chave usada numa EC2 real — não versionar, ver .gitignore).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEY_PATH="$SCRIPT_DIR/ssh/id_ed25519"

if [ -f "$KEY_PATH" ]; then
  echo "Já existe uma chave em $KEY_PATH — nada a fazer (apague o arquivo se quiser gerar outra)."
  exit 0
fi

mkdir -p "$SCRIPT_DIR/ssh"
ssh-keygen -t ed25519 -f "$KEY_PATH" -N "" -C "local-ec2-vector (teste local, descartável)"
chmod 600 "$KEY_PATH"
echo "Chave gerada em $KEY_PATH (e $KEY_PATH.pub)."
