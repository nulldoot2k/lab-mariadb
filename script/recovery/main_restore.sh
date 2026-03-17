#!/bin/bash
set -euo pipefail

# ============================================================
#  RESTORE DB: STANDBY → PRIMARY
#
#  PRIMARY  = DB gốc, bị lỗi, nay đã sống lại
#  STANDBY  = DB tạm thời, client đang dùng (data mới nhất)
#
#  Luồng:
#    1. Nhập thông tin + check SSH/container/DB
#    2. Confirm
#    3. Backup PRIMARY → /root/mariadb-backup/
#    4. Dump STANDBY + đếm rows snapshot
#    5. Transfer STANDBY → PRIMARY (rsync hoặc local relay)
#    6. Verify integrity (MD5 + size) → xóa .md5 sau verify
#    7. Restore vào PRIMARY
#    8. Verify row count
#    9. Notify Telegram
# ============================================================

# =========================================
# ⚙️  TELEGRAM CONFIG — chỉnh tại đây
# =========================================
TELE_TOKEN="your_bot_token_here"
TELE_CHAT_ID="your_chat_id_here"
TELE_THREAD_ID=""

# =========================================
# Colors
# =========================================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

ok()   { echo -e "  ${GREEN}✔${NC} $1"; }
fail() { echo -e "  ${RED}✘${NC} $1"; }
warn() { echo -e "  ${YELLOW}⚠${NC}  $1"; }
info() { echo -e "  ${CYAN}→${NC} $1"; }
dim()  { echo -e "  ${DIM}$1${NC}"; }
sep()  { echo -e "  ${DIM}────────────────────────────────────────${NC}"; }
step() { echo ""; echo -e "${CYAN}$1${NC}"; sep; }
quit() { echo ""; dim "Thoát."; echo ""; exit 0; }

confirm_yn() {
  local prompt="$1" ans
  read -rp "  ${prompt} (y/yes/no): " ans
  [[ "$ans" == "y" || "$ans" == "yes" ]]
}

# =========================================
# Telegram
# =========================================
tele_send() {
  local text="$1"
  if [ -z "$TELE_TOKEN" ] || [ "$TELE_TOKEN" = "your_bot_token_here" ] \
     || [ -z "$TELE_CHAT_ID" ]; then
    warn "Telegram chưa config — bỏ qua notify."
    return 0
  fi
  local extra=""
  [ -n "$TELE_THREAD_ID" ] && extra=", \"message_thread_id\": ${TELE_THREAD_ID}"
  local escaped
  escaped=$(printf '%s' "$text" | python3 -c \
    "import sys,json; print(json.dumps(sys.stdin.read()))" 2>/dev/null \
    || printf '"%s"' "$(printf '%s' "$text" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' ' ')")
  curl -s -X POST \
    "https://api.telegram.org/bot${TELE_TOKEN}/sendMessage" \
    -H "Content-Type: application/json" \
    -d "{\"chat_id\": \"${TELE_CHAT_ID}\", \"text\": ${escaped}, \"parse_mode\": \"HTML\"${extra}}" \
    > /dev/null 2>&1 || warn "Gửi Telegram thất bại."
}

# =========================================
# Helper: nhập password hiển thị *
# =========================================
read_pass() {
  local prompt="$1" varname="$2" pass="" char=""
  printf "%s" "$prompt"
  while IFS= read -r -s -n1 char; do
    if   [[ -z "$char" ]];                              then break
    elif [[ "$char" == $'\x7f' || "$char" == $'\b' ]]; then
      [ ${#pass} -gt 0 ] && { pass="${pass%?}"; printf "\b \b"; }
    else
      pass="${pass}${char}"; printf "*"
    fi
  done
  echo ""
  eval "$varname=\"$pass\""
}

# =========================================
# Helper: chạy query trên remote — file tạm
# =========================================
mysql_remote() {
  local ssh_port=$1 ssh_user=$2 ssh_host=$3
  local db_mode=$4 container=$5
  local db_user=$6 db_pass=$7 db_name=$8
  local query=$9
  local sf; sf=$(mktemp /tmp/restore_sql_XXXXXX)
  echo "$query" > "$sf"
  local remote_sf="/tmp/restore_sql_$$.sql"
  scp -P "$ssh_port" -o StrictHostKeyChecking=no \
    "$sf" "${ssh_user}@${ssh_host}:${remote_sf}" &>/dev/null
  rm -f "$sf"
  if [ "$db_mode" = "1" ]; then
    ssh -T -p "$ssh_port" -o StrictHostKeyChecking=no "${ssh_user}@${ssh_host}" \
      "docker exec -i ${container} mysql -u${db_user} -p${db_pass} -N 2>/dev/null \
       < ${remote_sf}; rm -f ${remote_sf}"
  else
    ssh -T -p "$ssh_port" -o StrictHostKeyChecking=no "${ssh_user}@${ssh_host}" \
      "mysql -u${db_user} -p${db_pass} -N 2>/dev/null \
       < ${remote_sf}; rm -f ${remote_sf}"
  fi
}

# =========================================
# Helper: đếm rows trên remote — shell script mini
# =========================================
count_rows_on() {
  local ssh_port=$1 ssh_user=$2 ssh_host=$3
  local db_mode=$4 container=$5
  local db_user=$6 db_pass=$7 db_name=$8
  local tables_input=${9:-}
  local sh; sh=$(mktemp /tmp/restore_cnt_XXXXXX.sh)
  cat > "$sh" << 'SHEOF'
#!/bin/bash
DB_MODE="$1"; CTR="$2"; DB_USER="$3"; DB_PASS="$4"
DB_NAME="$5"; TABLES_INPUT="$6"
if [ "$DB_MODE" = "1" ]; then
  MYSQL="docker exec -i $CTR mysql -u$DB_USER -p$DB_PASS -N 2>/dev/null"
else
  MYSQL="mysql -u$DB_USER -p$DB_PASS -N 2>/dev/null"
fi
if [ -n "$TABLES_INPUT" ]; then
  tbls="$TABLES_INPUT"
else
  tbls=$(echo "SHOW TABLES FROM \`$DB_NAME\`;" | eval $MYSQL 2>/dev/null)
fi
total=0
while IFS= read -r t; do
  [ -z "$t" ] && continue
  c=$(echo "SELECT COUNT(*) FROM \`$DB_NAME\`.\`$t\`;" | eval $MYSQL 2>/dev/null | tr -d '[:space:]')
  total=$(( total + ${c:-0} ))
done <<< "$tbls"
echo $total
SHEOF
  chmod +x "$sh"
  local remote_sh="/tmp/restore_cnt_$$.sh"
  scp -P "$ssh_port" -o StrictHostKeyChecking=no \
    "$sh" "${ssh_user}@${ssh_host}:${remote_sh}" &>/dev/null
  local result
  result=$(ssh -T -p "$ssh_port" -o StrictHostKeyChecking=no "${ssh_user}@${ssh_host}" \
    "bash ${remote_sh} '$db_mode' '$container' '$db_user' '$db_pass' '$db_name' '$tables_input'; \
     rm -f ${remote_sh}" 2>/dev/null | tr -d '[:space:]')
  rm -f "$sh"
  echo "${result:-0}"
}

# =========================================
# MAIN — LOOP CHÍNH
# =========================================
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}  RESTORE DB: STANDBY → PRIMARY${NC}"
echo    "  STANDBY = DB tạm, client đang dùng (data mới nhất)"
echo    "  PRIMARY = DB gốc, cần restore lại"
echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
echo ""

while true; do

START_TIME=$(date '+%Y-%m-%d %H:%M:%S')

# ── BƯỚC 1: Nhập thông tin + check ──────────────────────────
while true; do
  echo -e "  ${BOLD}── STANDBY ──${NC}"
  read -rp "  Host IP                           : " STBY_HOST
  read -rp "  SSH User (root)                   : " input; STBY_SSH_USER=${input:-root}
  read -rp "  SSH Port (22)                     : " input; STBY_SSH_PORT=${input:-22}
  echo     "  DB chạy dạng gì?   1) Docker   2) Service"
  while true; do
    read -rp "  Chọn [1/2]                        : " input
    [[ "$input" =~ ^[12]$ ]] && break || warn "Nhập 1 hoặc 2."
  done
  STBY_DB_MODE=$input; STBY_CONTAINER=""
  [ "$STBY_DB_MODE" = "1" ] && { read -rp "  Tên container                     : " STBY_CONTAINER; }
  read -rp "  Tên DB                            : " STBY_DB_NAME
  read -rp "  DB User (root)                    : " input; STBY_DB_USER=${input:-root}
  read_pass "  DB Password                       : " STBY_DB_PASS
  read -rp "  Thư mục tạm để dump (/tmp/migrate): " input; STBY_DIR=${input:-/tmp/migrate}

  echo ""
  echo -e "  ${BOLD}── PRIMARY ──${NC}"
  read -rp "  Host IP                              : " PRI_HOST
  read -rp "  SSH User (root)                      : " input; PRI_SSH_USER=${input:-root}
  read -rp "  SSH Port (22)                        : " input; PRI_SSH_PORT=${input:-22}
  echo     "  DB chạy dạng gì?   1) Docker   2) Service"
  while true; do
    read -rp "  Chọn [1/2]                           : " input
    [[ "$input" =~ ^[12]$ ]] && break || warn "Nhập 1 hoặc 2."
  done
  PRI_DB_MODE=$input; PRI_CONTAINER=""
  [ "$PRI_DB_MODE" = "1" ] && { read -rp "  Tên container                        : " PRI_CONTAINER; }
  read -rp "  Tên DB                               : " PRI_DB_NAME
  read -rp "  DB User (root)                       : " input; PRI_DB_USER=${input:-root}
  read_pass "  DB Password                          : " PRI_DB_PASS
  read -rp "  Thư mục tạm để nhận dump (/tmp/migrate): " input; PRI_DIR=${input:-/tmp/migrate}

  echo ""
  echo -e "  ${BOLD}── Verify ──${NC}"
  dim "  Tên bảng cần COUNT(*), cách nhau bằng dấu cách. Để trống = tất cả."
  read -rp "  Tables (Enter = all): " TABLES_INPUT

  # Check SSH + container + DB
  step "Kiểm tra kết nối SSH và DB..."
  local_err=false

  ssh -T -p "$STBY_SSH_PORT" -o ConnectTimeout=5 -o BatchMode=yes \
    -o StrictHostKeyChecking=no "${STBY_SSH_USER}@${STBY_HOST}" "echo ok" &>/dev/null \
    && ok "SSH STANDBY (${STBY_HOST})" \
    || { fail "Không SSH được vào STANDBY (${STBY_HOST})"; local_err=true; }

  ssh -T -p "$PRI_SSH_PORT" -o ConnectTimeout=5 -o BatchMode=yes \
    -o StrictHostKeyChecking=no "${PRI_SSH_USER}@${PRI_HOST}" "echo ok" &>/dev/null \
    && ok "SSH PRIMARY (${PRI_HOST})" \
    || { fail "Không SSH được vào PRIMARY (${PRI_HOST})"; local_err=true; }

  if [ "$local_err" = false ]; then
    if [ "$STBY_DB_MODE" = "1" ]; then
      stby_run=$(ssh -T -p "$STBY_SSH_PORT" -o StrictHostKeyChecking=no \
        "${STBY_SSH_USER}@${STBY_HOST}" \
        "docker inspect -f '{{.State.Running}}' '${STBY_CONTAINER}' 2>/dev/null || echo NOT_FOUND")
      if   [ "$stby_run" = "NOT_FOUND" ]; then
        fail "Container STANDBY '${STBY_CONTAINER}' không tồn tại"; local_err=true
      elif [ "$stby_run" != "true" ]; then
        fail "Container STANDBY '${STBY_CONTAINER}' không đang chạy"; local_err=true
      else
        ok "Container STANDBY '${STBY_CONTAINER}' OK"
      fi
    fi
    if [ "$PRI_DB_MODE" = "1" ] && [ "$local_err" = false ]; then
      pri_run=$(ssh -T -p "$PRI_SSH_PORT" -o StrictHostKeyChecking=no \
        "${PRI_SSH_USER}@${PRI_HOST}" \
        "docker inspect -f '{{.State.Running}}' '${PRI_CONTAINER}' 2>/dev/null || echo NOT_FOUND")
      if   [ "$pri_run" = "NOT_FOUND" ]; then
        fail "Container PRIMARY '${PRI_CONTAINER}' không tồn tại"; local_err=true
      elif [ "$pri_run" != "true" ]; then
        fail "Container PRIMARY '${PRI_CONTAINER}' không đang chạy"; local_err=true
      else
        ok "Container PRIMARY '${PRI_CONTAINER}' OK"
      fi
    fi
  fi

  if [ "$local_err" = false ]; then
    mysql_remote "$STBY_SSH_PORT" "$STBY_SSH_USER" "$STBY_HOST" \
      "$STBY_DB_MODE" "$STBY_CONTAINER" "$STBY_DB_USER" "$STBY_DB_PASS" "$STBY_DB_NAME" \
      "SELECT 1;" &>/dev/null \
      && ok "DB STANDBY OK" \
      || { fail "Không kết nối được DB trên STANDBY"; local_err=true; }
  fi

  if [ "$local_err" = false ]; then
    mysql_remote "$PRI_SSH_PORT" "$PRI_SSH_USER" "$PRI_HOST" \
      "$PRI_DB_MODE" "$PRI_CONTAINER" "$PRI_DB_USER" "$PRI_DB_PASS" "$PRI_DB_NAME" \
      "SELECT 1;" &>/dev/null \
      && ok "DB PRIMARY OK" \
      || { fail "Không kết nối được DB trên PRIMARY"; local_err=true; }
  fi

  [ "$local_err" = false ] && break
  echo ""
  confirm_yn "Nhập lại thông tin?" && { echo ""; continue; } || quit
done

# ── Confirm ─────────────────────────────────────────────────
echo ""
sep
echo -e "  ${BOLD}Xác nhận thông tin${NC}"
sep
info "STANDBY : ${STBY_SSH_USER}@${STBY_HOST}:${STBY_SSH_PORT}"
info "         DB=${STBY_DB_NAME} | $([ "$STBY_DB_MODE" = "1" ] && echo "docker (${STBY_CONTAINER})" || echo "service")"
info "PRIMARY : ${PRI_SSH_USER}@${PRI_HOST}:${PRI_SSH_PORT}"
info "         DB=${PRI_DB_NAME} | $([ "$PRI_DB_MODE" = "1" ] && echo "docker (${PRI_CONTAINER})" || echo "service")"
sep
echo ""
warn "DB hiện tại trên PRIMARY (${PRI_DB_NAME}) sẽ bị XÓA"
warn "và thay bằng data mới nhất từ STANDBY."
dim  "Backup rollback lưu tại PRIMARY: /root/mariadb-backup/"
dim  "File dump tạm lưu ở /tmp/migrate/ — tự xóa sau khi xong."
echo ""
confirm_yn "Tiếp tục?" || { echo "  Hủy."; break; }

# ── Paths ────────────────────────────────────────────────────
DUMP_FNAME="dump_${STBY_DB_NAME}_$(date +%Y%m%d_%H%M%S).sql.gz"
DUMP_ON_STBY="${STBY_DIR}/${DUMP_FNAME}"
DUMP_ON_PRI="${PRI_DIR}/${DUMP_FNAME}"
BACKUP_DIR_PRI="/root/mariadb-backup"
BACKUP_FILE="${BACKUP_DIR_PRI}/dump_${PRI_DB_NAME}_$(date +%Y%m%d_%H%M%S).sql.gz"
ROW_COUNT_STBY=0; ROW_COUNT_PRI=0

ssh -T -p "$STBY_SSH_PORT" -o StrictHostKeyChecking=no \
  "${STBY_SSH_USER}@${STBY_HOST}" "mkdir -p ${STBY_DIR}" &>/dev/null
ssh -T -p "$PRI_SSH_PORT" -o StrictHostKeyChecking=no \
  "${PRI_SSH_USER}@${PRI_HOST}" "mkdir -p ${PRI_DIR} ${BACKUP_DIR_PRI}" &>/dev/null

# ── BƯỚC 2: Backup PRIMARY ───────────────────────────────────
step "[1/5] Backup DB hiện tại trên PRIMARY (phòng rollback)..."

local_bak_sh=$(mktemp /tmp/restore_bak_XXXXXX.sh)
cat > "$local_bak_sh" << 'SHEOF'
#!/bin/bash
set -euo pipefail
DB_MODE="$1"; CTR="$2"; DB_USER="$3"; DB_PASS="$4"; DB_NAME="$5"; OUT="$6"
ERR=$(mktemp)
if [ "$DB_MODE" = "1" ]; then
  docker exec "$CTR" mysqldump --single-transaction --routines --triggers --opt \
    -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" 2>"$ERR" | gzip > "$OUT"
else
  mysqldump --single-transaction --routines --triggers --opt \
    -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" 2>"$ERR" | gzip > "$OUT"
fi
if grep -v "Using a password" "$ERR" | grep -qi "error\|unknown\|denied\|failed"; then
  cat "$ERR" >&2; rm -f "$ERR" "$OUT"; exit 1
fi
rm -f "$ERR"
SIZE=$(du -b "$OUT" | cut -f1)
if [ "${SIZE:-0}" -lt 100 ]; then
  echo "Backup file rỗng (${SIZE} bytes)" >&2; rm -f "$OUT"; exit 1
fi
md5sum "$OUT" > "$OUT.md5"
SHEOF
chmod +x "$local_bak_sh"
remote_bak_sh="/tmp/restore_bak_$$.sh"
scp -P "$PRI_SSH_PORT" -o StrictHostKeyChecking=no \
  "$local_bak_sh" "${PRI_SSH_USER}@${PRI_HOST}:${remote_bak_sh}" &>/dev/null
rm -f "$local_bak_sh"
ssh -T -p "$PRI_SSH_PORT" -o StrictHostKeyChecking=no "${PRI_SSH_USER}@${PRI_HOST}" \
  "bash ${remote_bak_sh} '$PRI_DB_MODE' '$PRI_CONTAINER' \
   '$PRI_DB_USER' '$PRI_DB_PASS' '$PRI_DB_NAME' '${BACKUP_FILE}'; \
   rm -f ${remote_bak_sh}" \
  && ok "Backup PRIMARY OK → ${BACKUP_FILE}" \
  || { fail "Backup PRIMARY thất bại"; exit 1; }

# ── BƯỚC 3: Dump STANDBY ─────────────────────────────────────
step "[2/5] Dump DB từ STANDBY + đếm rows snapshot..."

local_dump_sh=$(mktemp /tmp/restore_dump_XXXXXX.sh)
cat > "$local_dump_sh" << 'SHEOF'
#!/bin/bash
set -euo pipefail
DB_MODE="$1"; CTR="$2"; DB_USER="$3"; DB_PASS="$4"; DB_NAME="$5"; OUT="$6"
ERR=$(mktemp)
if [ "$DB_MODE" = "1" ]; then
  docker exec "$CTR" mysqldump --single-transaction --routines --triggers --opt \
    -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" 2>"$ERR" | gzip > "$OUT"
else
  mysqldump --single-transaction --routines --triggers --opt \
    -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" 2>"$ERR" | gzip > "$OUT"
fi
if grep -v "Using a password" "$ERR" | grep -qi "error\|unknown\|denied\|failed"; then
  cat "$ERR" >&2; rm -f "$ERR" "$OUT"; exit 1
fi
rm -f "$ERR"
SIZE=$(du -b "$OUT" | cut -f1)
if [ "${SIZE:-0}" -lt 100 ]; then
  echo "Dump file rỗng hoặc quá nhỏ (${SIZE} bytes)" >&2; rm -f "$OUT"; exit 1
fi
md5sum "$OUT" > "$OUT.md5"
du -b "$OUT" | cut -f1 > "$OUT.size"
SHEOF
chmod +x "$local_dump_sh"
remote_dump_sh="/tmp/restore_dump_$$.sh"
scp -P "$STBY_SSH_PORT" -o StrictHostKeyChecking=no \
  "$local_dump_sh" "${STBY_SSH_USER}@${STBY_HOST}:${remote_dump_sh}" &>/dev/null
rm -f "$local_dump_sh"
ssh -T -p "$STBY_SSH_PORT" -o StrictHostKeyChecking=no "${STBY_SSH_USER}@${STBY_HOST}" \
  "bash ${remote_dump_sh} '$STBY_DB_MODE' '$STBY_CONTAINER' \
   '$STBY_DB_USER' '$STBY_DB_PASS' '$STBY_DB_NAME' '${DUMP_ON_STBY}'; \
   rm -f ${remote_dump_sh}" \
  && ok "Dump STANDBY OK → ${DUMP_ON_STBY}" \
  || { fail "Dump STANDBY thất bại"; exit 1; }

info "Đếm rows snapshot trên STANDBY..."
ROW_COUNT_STBY=$(count_rows_on \
  "$STBY_SSH_PORT" "$STBY_SSH_USER" "$STBY_HOST" \
  "$STBY_DB_MODE" "$STBY_CONTAINER" \
  "$STBY_DB_USER" "$STBY_DB_PASS" "$STBY_DB_NAME" \
  "$TABLES_INPUT")
ok "Rows STANDBY snapshot: ${ROW_COUNT_STBY}"

# ── BƯỚC 4: Transfer ─────────────────────────────────────────
step "[3/5] Transfer dump STANDBY → PRIMARY..."

HAVE_KEY=false
ssh -T -p "$STBY_SSH_PORT" -o StrictHostKeyChecking=no "${STBY_SSH_USER}@${STBY_HOST}" \
  "ssh -p ${PRI_SSH_PORT} -o BatchMode=yes -o ConnectTimeout=5 \
   -o StrictHostKeyChecking=no ${PRI_SSH_USER}@${PRI_HOST} echo ok 2>/dev/null" \
  &>/dev/null && HAVE_KEY=true || HAVE_KEY=false

if [ "$HAVE_KEY" = true ]; then
  info "Dùng rsync trực tiếp STANDBY → PRIMARY..."
  ssh -T -p "$STBY_SSH_PORT" -o StrictHostKeyChecking=no "${STBY_SSH_USER}@${STBY_HOST}" \
    "rsync -az --partial \
     -e 'ssh -p ${PRI_SSH_PORT} -o StrictHostKeyChecking=no' \
     ${DUMP_ON_STBY} ${DUMP_ON_STBY}.md5 ${DUMP_ON_STBY}.size \
     ${PRI_SSH_USER}@${PRI_HOST}:${PRI_DIR}/" \
    && ok "Transfer rsync OK" \
    || { fail "rsync thất bại"; exit 1; }
else
  warn "Không có SSH key STANDBY → PRIMARY. Dùng local relay..."
  local_tmp=$(mktemp -d /tmp/restore_relay_XXXXXX)
  scp -P "$STBY_SSH_PORT" -o StrictHostKeyChecking=no \
    "${STBY_SSH_USER}@${STBY_HOST}:${DUMP_ON_STBY}" \
    "${STBY_SSH_USER}@${STBY_HOST}:${DUMP_ON_STBY}.md5" \
    "${STBY_SSH_USER}@${STBY_HOST}:${DUMP_ON_STBY}.size" \
    "$local_tmp/" \
    && ok "Kéo dump về local OK" \
    || { fail "Kéo dump về local thất bại"; rm -rf "$local_tmp"; exit 1; }
  scp -P "$PRI_SSH_PORT" -o StrictHostKeyChecking=no \
    "$local_tmp/${DUMP_FNAME}" \
    "$local_tmp/${DUMP_FNAME}.md5" \
    "$local_tmp/${DUMP_FNAME}.size" \
    "${PRI_SSH_USER}@${PRI_HOST}:${PRI_DIR}/" \
    && ok "Đẩy dump lên PRIMARY OK" \
    || { fail "Đẩy dump lên PRIMARY thất bại"; rm -rf "$local_tmp"; exit 1; }
  rm -rf "$local_tmp"
fi

ssh -T -p "$STBY_SSH_PORT" -o StrictHostKeyChecking=no "${STBY_SSH_USER}@${STBY_HOST}" \
  "rm -f ${DUMP_ON_STBY} ${DUMP_ON_STBY}.md5 ${DUMP_ON_STBY}.size" &>/dev/null
info "Đã xóa file tạm trên STANDBY."

# ── BƯỚC 5: Verify integrity ─────────────────────────────────
step "[4/5] Kiểm tra integrity file dump trên PRIMARY..."

ssh -T -p "$PRI_SSH_PORT" -o StrictHostKeyChecking=no "${PRI_SSH_USER}@${PRI_HOST}" \
  "cd ${PRI_DIR} \
   && md5sum -c ${DUMP_FNAME}.md5 --quiet 2>/dev/null \
   && ACTUAL=\$(du -b ${DUMP_FNAME} | cut -f1) \
   && EXPECT=\$(cat ${DUMP_FNAME}.size) \
   && [ \"\$ACTUAL\" = \"\$EXPECT\" ] \
   && rm -f ${DUMP_FNAME}.md5 ${DUMP_FNAME}.size \
   && echo ok || echo fail" \
  | grep -q "^ok" \
  && ok "Integrity OK (MD5 + size khớp)" \
  || { fail "File dump bị lỗi — dừng, không restore."; exit 1; }

# ── BƯỚC 6: Restore ──────────────────────────────────────────
step "[5/5] Restore vào PRIMARY (DROP & recreate '${PRI_DB_NAME}')..."

mysql_remote "$PRI_SSH_PORT" "$PRI_SSH_USER" "$PRI_HOST" \
  "$PRI_DB_MODE" "$PRI_CONTAINER" "$PRI_DB_USER" "$PRI_DB_PASS" "$PRI_DB_NAME" \
  "DROP DATABASE IF EXISTS \`${PRI_DB_NAME}\`; \
   CREATE DATABASE \`${PRI_DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" \
  &>/dev/null \
  && ok "DROP & CREATE DB OK" \
  || { fail "Không DROP/CREATE được DB trên PRIMARY"; exit 1; }

local_import_sh=$(mktemp /tmp/restore_import_XXXXXX.sh)
cat > "$local_import_sh" << 'SHEOF'
#!/bin/bash
set -euo pipefail
DB_MODE="$1"; CTR="$2"; DB_USER="$3"; DB_PASS="$4"; DB_NAME="$5"; DUMP_FILE="$6"
if [ "$DB_MODE" = "1" ]; then
  gunzip -c "$DUMP_FILE" | docker exec -i "$CTR" mysql -u"$DB_USER" -p"$DB_PASS" "$DB_NAME"
else
  gunzip -c "$DUMP_FILE" | mysql -u"$DB_USER" -p"$DB_PASS" "$DB_NAME"
fi
SHEOF
chmod +x "$local_import_sh"
remote_import_sh="/tmp/restore_import_$$.sh"
scp -P "$PRI_SSH_PORT" -o StrictHostKeyChecking=no \
  "$local_import_sh" "${PRI_SSH_USER}@${PRI_HOST}:${remote_import_sh}" &>/dev/null
rm -f "$local_import_sh"

ssh -T -p "$PRI_SSH_PORT" -o StrictHostKeyChecking=no "${PRI_SSH_USER}@${PRI_HOST}" \
  "bash ${remote_import_sh} '$PRI_DB_MODE' '$PRI_CONTAINER' \
   '$PRI_DB_USER' '$PRI_DB_PASS' '$PRI_DB_NAME' '${DUMP_ON_PRI}'; \
   rm -f ${remote_import_sh}" \
  && ok "Restore OK" \
  || { fail "Restore FAIL — backup tại: ${BACKUP_FILE}"; exit 1; }

# ── BƯỚC 7: Verify row count ─────────────────────────────────
step "Verify row count..."

ROW_COUNT_PRI=$(count_rows_on \
  "$PRI_SSH_PORT" "$PRI_SSH_USER" "$PRI_HOST" \
  "$PRI_DB_MODE" "$PRI_CONTAINER" \
  "$PRI_DB_USER" "$PRI_DB_PASS" "$PRI_DB_NAME" \
  "$TABLES_INPUT")

# Xóa file dump tạm + .md5 của backup (chỉ giữ .sql.gz)
ssh -T -p "$PRI_SSH_PORT" -o StrictHostKeyChecking=no "${PRI_SSH_USER}@${PRI_HOST}" \
  "rm -f ${DUMP_ON_PRI} ${DUMP_ON_PRI}.md5 ${DUMP_ON_PRI}.size \
   '${BACKUP_FILE}.md5'" &>/dev/null || true

END_TIME=$(date '+%Y-%m-%d %H:%M:%S')

echo ""
sep
info "Rows STANDBY (lúc dump)    : ${ROW_COUNT_STBY}"
info "Rows PRIMARY (sau restore) : ${ROW_COUNT_PRI}"
sep

if [ "${ROW_COUNT_PRI}" != "${ROW_COUNT_STBY}" ]; then
  fail "VERIFY FAIL: Rows không khớp (standby=${ROW_COUNT_STBY}, primary=${ROW_COUNT_PRI})"
  warn "Backup còn tại PRIMARY: ${BACKUP_FILE}"
  warn "Chạy main_rollback.sh để khôi phục."
  tele_send "❌ <b>RESTORE DB — FAIL</b>
STANDBY: <code>${STBY_HOST}</code> → PRIMARY: <code>${PRI_HOST}</code>
DB: <code>${STBY_DB_NAME}</code> → <code>${PRI_DB_NAME}</code>
Lỗi: Rows không khớp (standby=${ROW_COUNT_STBY}, primary=${ROW_COUNT_PRI})
Backup rollback: <code>${BACKUP_FILE}</code>
Start: ${START_TIME} / End: ${END_TIME}"
  exit 1
fi

ok "VERIFY OK — rows khớp (${ROW_COUNT_PRI})"

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}  ✅ HOÀN TẤT${NC}"
info "Backup rollback tại : ${BACKUP_FILE}"
dim  "Xóa thủ công khi không cần rollback nữa."
echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${NC}"

tele_send "✅ <b>RESTORE DB — DONE</b>
STANDBY: <code>${STBY_HOST}</code> → PRIMARY: <code>${PRI_HOST}</code>
DB: <code>${STBY_DB_NAME}</code> → <code>${PRI_DB_NAME}</code>
Rows: ${ROW_COUNT_STBY} ✔
Backup rollback: <code>${BACKUP_FILE}</code>
Start: ${START_TIME} / End: ${END_TIME}"

# ── Tiếp tục? ────────────────────────────────────────────────
echo ""
confirm_yn "Thực hiện restore thêm lần nữa?" || break
echo ""

done  # end LOOP CHÍNH

echo ""
