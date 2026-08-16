#!/bin/bash
# Formata (se ainda não tiver filesystem) e monta em /mnt/vector o disco
# extra declarado no Vagrantfile (config.vm.disk :disk, name: "vector-data")
# — simula o volume EBS que, numa EC2 real, já chega montado nesse caminho
# antes do Ansible rodar (vector-provision.yml não mexe em volume, só
# valida que o mount existe — ver AWS.md).
set -euo pipefail

MOUNT_POINT=/mnt/vector

# O disco extra é o único disco "disk" sem partição e sem filesystem
# reconhecido ainda — mais robusto que fixar /dev/sdb, já que o nome pode
# variar (sd*, xvd*, nvme*) conforme o controller escolhido pelo VirtualBox.
DEVICE=""
for dev in /dev/sd? /dev/xvd? /dev/nvme?n1; do
  [ -b "$dev" ] || continue
  if ! blkid "$dev" >/dev/null 2>&1 && [ "$(lsblk -ndo MOUNTPOINT "$dev" 2>/dev/null)" = "" ]; then
    DEVICE="$dev"
    break
  fi
done

if [ -z "$DEVICE" ]; then
  echo "Nenhum disco extra sem filesystem encontrado (talvez já esteja formatado)." >&2
  # Se já rodou antes, o disco já tem filesystem — cai para o caminho normal
  # abaixo usando o que já estiver em /etc/fstab.
else
  echo "==> Formatando $DEVICE (ext4) para $MOUNT_POINT..."
  mkfs.ext4 -F -q "$DEVICE"
fi

mkdir -p "$MOUNT_POINT"

# Garante entrada em /etc/fstab (idempotente) para sobreviver a reboot,
# usando UUID em vez do device path (mais estável).
FSTAB_DEVICE="${DEVICE:-$(lsblk -ndo NAME,FSTYPE | awk '$2=="ext4"{print "/dev/"$1}' | grep -v "$(findmnt -n -o SOURCE /)" | head -n1)}"
UUID="$(blkid -s UUID -o value "$FSTAB_DEVICE")"

if ! grep -q "$MOUNT_POINT" /etc/fstab; then
  echo "UUID=$UUID $MOUNT_POINT ext4 defaults,nofail 0 2" >> /etc/fstab
fi

mountpoint -q "$MOUNT_POINT" || mount "$MOUNT_POINT"

echo "==> $MOUNT_POINT pronto:"
df -h "$MOUNT_POINT"
