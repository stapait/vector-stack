#!/bin/bash
# Script avulso (não roda como serviço) — mover para /archive os logs .gz de
# pastas de data com mais de 30 dias, mantendo a estrutura
# {app}/{data}/{instancia}/. Rode manualmente ou agende via cron do host.
#
# Uso:
#   ./archive-logs.sh [caminho para data/logs] [dias de retenção]
#
# Exemplo (cron do host, todo dia às 03:00):
#   0 3 * * * /caminho/para/docker/concentrador/scripts/archive-logs.sh >> /var/log/archive-logs.log 2>&1
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_ROOT="${1:-$SCRIPT_DIR/../data/logs}"
RETENTION_DAYS="${2:-30}"
ARCHIVE_ROOT="$LOG_ROOT/archive"

LOG_ROOT="$(cd "$LOG_ROOT" && pwd)"
CUTOFF=$(date -d "-${RETENTION_DAYS} days" +%Y-%m-%d)

mkdir -p "$ARCHIVE_ROOT"

find "$LOG_ROOT" -mindepth 2 -maxdepth 2 -type d | while read -r date_dir; do
  case "$date_dir" in
    "$ARCHIVE_ROOT"/*) continue ;;
  esac

  date_name="$(basename "$date_dir")"
  app_name="$(basename "$(dirname "$date_dir")")"

  [ "$app_name" = "archive" ] && continue
  [[ "$date_name" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || continue
  [[ "$date_name" < "$CUTOFF" ]] || continue

  dest_date_dir="$ARCHIVE_ROOT/$app_name/$date_name"

  find "$date_dir" -type f -name '*.gz' -print0 | while IFS= read -r -d '' f; do
    rel="${f#"$date_dir"/}"
    dest="$dest_date_dir/$rel"
    mkdir -p "$(dirname "$dest")"
    mv "$f" "$dest"
    echo "$(date -Iseconds) arquivado: $f -> $dest"
  done

  # limpa diretórios que ficaram vazios depois de mover os .gz
  find "$date_dir" -mindepth 1 -type d -empty -delete 2>/dev/null || true
  find "$date_dir" -mindepth 0 -maxdepth 0 -empty -delete 2>/dev/null || true
done
