#!/usr/bin/env bash
# Point-in-time backup para MariaDB: dump diário com posição do binlog + envio de binlogs ao R2.
set -uo pipefail

: "${NAME:?}" "${DB_HOST:?}" "${DB_USER:?}" "${DB_PASSWORD:?}" "${DATABASES:?}"
: "${R2_ENDPOINT:?}" "${R2_BUCKET:?}" "${R2_ACCESS_KEY_ID:?}" "${R2_SECRET_ACCESS_KEY:?}"
INTERVAL="${INTERVAL:-300}"     # segundos entre envios de binlog
DUMP_HOUR="${DUMP_HOUR:-6}"     # hora UTC do dump diário (6 = 03h em Brasília)

export MYSQL_PWD="$DB_PASSWORD"
export RCLONE_CONFIG_R2_TYPE=s3 RCLONE_CONFIG_R2_PROVIDER=Cloudflare \
  RCLONE_CONFIG_R2_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" \
  RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY" \
  RCLONE_CONFIG_R2_ENDPOINT="$R2_ENDPOINT" RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true

DEST="r2:$R2_BUCKET/pitr/$NAME"
WORK=/work
mkdir -p "$WORK/binlog"

log()   { echo "$(date -u '+%F %T') $*"; }
alert() {
  log "ALERTA: $*"
  [ -n "${TG_TOKEN:-}" ] || return 0
  curl -s -m 10 "https://api.telegram.org/bot$TG_TOKEN/sendMessage" \
    -d chat_id="${TG_CHAT_ID:-}" -d message_thread_id="${TG_THREAD_ID:-}" \
    --data-urlencode text="[PITR $NAME] FALHA: $*" >/dev/null
}
q() { mariadb -h "$DB_HOST" -u "$DB_USER" -N -B -e "$1"; }

full_dump() {
  local f="$WORK/full_$(date -u +%Y-%m-%d_%H%M%S).sql.gz"
  log "dump completo -> $(basename "$f")"
  # shellcheck disable=SC2086
  if mariadb-dump -h "$DB_HOST" -u "$DB_USER" --single-transaction --master-data=2 --flush-logs \
       --routines --triggers --events --databases $DATABASES | gzip > "$f" \
     && rclone copy "$f" "$DEST/full/"; then
    rm -f "$f"; log "dump enviado"; return 0
  fi
  rm -f "$f"; return 1
}

ship_binlogs() {
  q "FLUSH BINARY LOGS" || return 1
  local logs uploaded n
  mapfile -t logs < <(q "SHOW BINARY LOGS" | awk '{print $1}')
  n=${#logs[@]}
  [ "$n" -ge 2 ] || return 0
  uploaded=$(rclone lsf "$DEST/binlog/" 2>/dev/null || true)
  for l in "${logs[@]:0:n-1}"; do            # o último é o arquivo ativo
    grep -qx "$l" <<<"$uploaded" && continue
    mariadb-binlog --read-from-remote-server -h "$DB_HOST" -u "$DB_USER" \
      --raw --result-file="$WORK/binlog/" "$l" || return 1
    rclone copy "$WORK/binlog/$l" "$DEST/binlog/" || return 1
    rm -f "$WORK/binlog/$l"
    log "binlog enviado: $l"
  done
}

has_dump_today() { rclone lsf "$DEST/full/" --include "full_$(date -u +%Y-%m-%d)_*" 2>/dev/null | grep -q .; }
has_any_dump()   { rclone lsf "$DEST/full/" 2>/dev/null | grep -q .; }

log "iniciando PITR para $NAME (bancos: $DATABASES)"
has_any_dump || full_dump || alert "primeiro dump completo falhou"

fails=0; dump_alert_day=""
while true; do
  if [ "$((10#$(date -u +%H)))" -ge "$DUMP_HOUR" ] && ! has_dump_today; then
    if ! full_dump && [ "$dump_alert_day" != "$(date -u +%F)" ]; then
      alert "dump diário falhou"; dump_alert_day="$(date -u +%F)"
    fi
  fi
  if ship_binlogs; then
    fails=0
    [ -n "${HC_URL:-}" ] && curl -fsS -m 10 "$HC_URL" >/dev/null
  else
    fails=$((fails + 1))
    [ "$fails" -eq 2 ] && alert "envio de binlog falhou 2 vezes seguidas"
  fi
  sleep "$INTERVAL"
done
