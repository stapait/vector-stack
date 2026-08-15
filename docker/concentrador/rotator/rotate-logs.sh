#!/bin/bash
# Roda a cada hora (ver crontab). Para cada app/instância em /mnt/logs, "fecha"
# o log da hora que acabou de terminar:
#   1. copia app.log -> app-{HH}.log (HH = hora que passou, não a atual)
#   2. trunca app.log no lugar (copytruncate) para o Vector continuar
#      escrevendo no mesmo arquivo/inode sem interrupção
#   3. compacta app-{HH}.log -> app-{HH}.log.gz
#
# O copytruncate só é seguro porque o Vector escreve em modo append (O_APPEND):
# truncar o arquivo não invalida o file descriptor que o Vector mantém aberto,
# a próxima escrita simplesmente continua a partir do novo fim de arquivo.
set -euo pipefail

LOG_ROOT="${LOG_ROOT:-/mnt/logs}"

prev_epoch=$(( $(date +%s) - 3600 ))
prev_hour=$(date -d "@${prev_epoch}" +%H)
prev_date=$(date -d "@${prev_epoch}" +%Y-%m-%d)

[ -d "$LOG_ROOT" ] || exit 0

find "$LOG_ROOT" -mindepth 1 -maxdepth 1 -type d | while read -r app_dir; do
  app="$(basename "$app_dir")"
  [ "$app" = "archive" ] && continue

  date_dir="$app_dir/$prev_date"
  [ -d "$date_dir" ] || continue

  find "$date_dir" -mindepth 1 -maxdepth 1 -type d | while read -r instance_dir; do
    current_log="$instance_dir/${app}.log"
    [ -s "$current_log" ] || continue

    rotated="$instance_dir/${app}-${prev_hour}.log"
    cp "$current_log" "$rotated"
    : > "$current_log"
    gzip -f "$rotated"
    echo "$(date -Iseconds) rotacionado: $rotated.gz"
  done
done
