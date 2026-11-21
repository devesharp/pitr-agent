#!/usr/bin/env bash
# Restaura um banco até um horário exato, baixando dump + binlogs do R2.
# Uso: TARGET_HOST=<host> TARGET_PASSWORD=<senha root> pitr-restore.sh "AAAA-MM-DD HH:MM:SS"
#      O horário é de Brasília. Usa as mesmas variáveis R2_* e NAME do agente.
set -euo pipefail

: "${1:?informe o horário de Brasília, ex.: \"2026-11-21 01:05:00\"}"
: "${NAME:?}" "${R2_ENDPOINT:?}" "${R2_BUCKET:?}" "${R2_ACCESS_KEY_ID:?}" "${R2_SECRET_ACCESS_KEY:?}"
: "${TARGET_HOST:?defina TARGET_HOST (banco descartável ou novo)}" "${TARGET_PASSWORD:?}"
TARGET_USER="${TARGET_USER:-root}"

if [ "$TARGET_HOST" = "${DB_HOST:-}" ] && [ "${FORCE:-0}" != "1" ]; then
  echo "TARGET_HOST é o banco de produção. Restaure num banco novo ou use FORCE=1." >&2
  exit 1
fi

export RCLONE_CONFIG_R2_TYPE=s3 RCLONE_CONFIG_R2_PROVIDER=Cloudflare \
  RCLONE_CONFIG_R2_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" \
  RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY" \
  RCLONE_CONFIG_R2_ENDPOINT="${R2_ENDPOINT%/}" RCLONE_CONFIG_R2_REGION=auto \
  RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true
SRC="r2:$R2_BUCKET/pitr/$NAME"

STOP_UTC=$(date -u -d "TZ=\"America/Sao_Paulo\" $1" '+%F %T')
STOP_KEY=$(date -u -d "$STOP_UTC" '+%F_%H%M%S')
echo "Alvo: $1 (Brasília) = $STOP_UTC UTC"

WORK=$(mktemp -d /tmp/restore.XXXX)
trap 'rm -rf "$WORK"' EXIT

# 1. Dump completo mais recente antes do horário alvo
FULL=$(rclone lsf "$SRC/full/" | sort | awk -v k="full_${STOP_KEY}" '$0 < k' | tail -1)
[ -n "$FULL" ] || { echo "Nenhum dump completo anterior a $STOP_UTC UTC." >&2; exit 1; }
echo "Dump base: $FULL"
rclone copy "$SRC/full/$FULL" "$WORK/"

POSLINE=$(zcat "$WORK/$FULL" | grep -m1 "CHANGE MASTER TO")
START_FILE=$(sed -E "s/.*MASTER_LOG_FILE='([^']+)'.*/\1/" <<<"$POSLINE")
START_POS=$(sed -E "s/.*MASTER_LOG_POS=([0-9]+).*/\1/" <<<"$POSLINE")
echo "Posição do binlog no dump: $START_FILE:$START_POS"

# 2. Binlogs a partir da posição do dump
mapfile -t LOGS < <(rclone lsf "$SRC/binlog/" | sort | awk -v f="$START_FILE" '$0 >= f')
[ "${#LOGS[@]}" -gt 0 ] && [ "${LOGS[0]}" = "$START_FILE" ] \
  || { echo "Binlog $START_FILE não está no R2." >&2; exit 1; }
for l in "${LOGS[@]}"; do rclone copy "$SRC/binlog/$l" "$WORK/binlog/"; done
echo "Binlogs baixados: ${#LOGS[@]} (${LOGS[0]} até ${LOGS[-1]})"

export MYSQL_PWD="$TARGET_PASSWORD"
DB=(mariadb -h "$TARGET_HOST" -u "$TARGET_USER")

# 3. Prévia do que será reaplicado
echo "Operações que serão reaplicadas após o dump:"
mariadb-binlog --base64-output=decode-rows -v --start-position="$START_POS" \
  --stop-datetime="$STOP_UTC" "${LOGS[@]/#/$WORK/binlog/}" \
  | grep -E '^### (INSERT|UPDATE|DELETE)' | sort | uniq -c || true

# 4. Restaurar dump e aplicar binlogs até o horário alvo
echo "Restaurando dump..."
(echo "SET SESSION sql_log_bin=0;"; zcat "$WORK/$FULL") | "${DB[@]}"
echo "Aplicando binlogs até $STOP_UTC UTC..."
mariadb-binlog --disable-log-bin --start-position="$START_POS" --stop-datetime="$STOP_UTC" \
  "${LOGS[@]/#/$WORK/binlog/}" | "${DB[@]}"
echo "Restore concluído."
