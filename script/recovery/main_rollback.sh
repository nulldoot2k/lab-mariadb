#!/bin/bash
set -euo pipefail

# ============================================================
#  ROLLBACK DB TARGET
#  Khôi phục DB về trạng thái từ file backup
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
  # confirm_yn "prompt" → return 0 nếu y/yes, 1 nếu không
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
# Helper: chạy query trên remote — file tạm
# =========================================
mysql_remote() {
  local ssh_port=$1 ssh_user=$2 ssh_host=$3
  local db_mode=$4 container=$5
  local db_user=$6 db_pass=$7 db_name=$8
  local query=$9

  local sf; sf=$(mktemp /tmp/rollback_sql_XXXXXX)
  echo "$query" > "$sf"
  local remote_sf="/tmp/rollback_sql_$$.sql"
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
# Helper: đếm rows trên remote
# =========================================
count_rows_on() {
  local ssh_port=$1 ssh_user=$2 ssh_host=$3
  local db_mode=$4 container=$5
  local db_user=$6 db_pass=$7 db_name=$8

  local sh; sh=$(mktemp /tmp/rollback_cnt_XXXXXX.sh)
  cat > "$sh" << 'SHEOF'
#!/bin/bash
DB_MODE="$1"; CTR="$2"; DB_USER="$3"; DB_PASS="$4"; DB_NAME="$5"
if [ "$DB_MODE" = "1" ]; then
  MYSQL="docker exec -i $CTR mysql -u$DB_USER -p$DB_PASS -N 2>/dev/null"
else
  MYSQL="mysql -u$DB_USER -p$DB_PASS -N 2>/dev/null"
fi
TABLES=$(echo "SHOW TABLES FROM \`$DB_NAME\`;" | eval $MYSQL 2>/dev/null)
total=0
while IFS= read -r t; do
  [ -z "$t" ] && continue
  c=$(echo "SELECT COUNT(*) FROM \`$DB_NAME\`.\`$t\`;" | eval $MYSQL 2>/dev/null | tr -d '[:space:]')
  total=$(( total + ${c:-0} ))
done <<< "$TABLES"
echo $total
SHEOF
  chmod +x "$sh"
  local remote_sh="/tmp/rollback_cnt_$$.sh"
  scp -P "$ssh_port" -o StrictHostKeyChecking=no \
    "$sh" "${ssh_user}@${ssh_host}:${remote_sh}" &>/dev/null
  local result
  result=$(ssh -T -p "$ssh_port" -o StrictHostKeyChecking=no "${ssh_user}@${ssh_host}" \
    "bash ${remote_sh} '$db_mode' '$container' '$db_user' '$db_pass' '$db_name'; \
     rm -f ${remote_sh}" 2>/dev/null | tr -d '[:space:]')
  rm -f "$sh"
  echo "${result:-0}"
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
# MAIN
# =========================================
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}  ROLLBACK DB TARGET${NC}"
echo    "  Khôi phục DB về trạng thái từ file backup"
echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
echo ""

# =========================================
# LOOP CHÍNH
# =========================================
while true; do

START_TIME=$(date '+%Y-%m-%d %H:%M:%S')

# ── BƯỚC 1: Nhập thông tin + check ──────────────────────────
while true; do
  echo -e "  ${BOLD}── TARGET ──${NC}"
  read -rp "  Host IP          : " TGT_HOST
  read -rp "  SSH User (root)  : " input; TGT_SSH_USER=${input:-root}
  read -rp "  SSH Port (22)    : " input; TGT_SSH_PORT=${input:-22}
  echo     "  DB chạy dạng gì?   1) Docker   2) Service"
  while true; do
    read -rp "  Chọn [1/2]       : " input
    [[ "$input" =~ ^[12]$ ]] && break || warn "Nhập 1 hoặc 2."
  done
  TGT_DB_MODE=$input
  TGT_CONTAINER=""
  [ "$TGT_DB_MODE" = "1" ] && { read -rp "  Tên container    : " TGT_CONTAINER; }
  read -rp "  Tên DB           : " TGT_DB_NAME
  read -rp "  DB User (root)   : " input; TGT_DB_USER=${input:-root}
  read_pass "  DB Password      : " TGT_DB_PASS

  step "Kiểm tra kết nối..."
  local_err=false

  ssh -T -p "$TGT_SSH_PORT" -o ConnectTimeout=5 -o BatchMode=yes \
    -o StrictHostKeyChecking=no "${TGT_SSH_USER}@${TGT_HOST}" "echo ok" &>/dev/null \
    && ok "SSH TARGET (${TGT_HOST})" \
    || { fail "Không SSH được vào TARGET (${TGT_HOST})"; local_err=true; }

  if [ "$local_err" = false ] && [ "$TGT_DB_MODE" = "1" ]; then
    tgt_running=$(ssh -T -p "$TGT_SSH_PORT" -o StrictHostKeyChecking=no \
      "${TGT_SSH_USER}@${TGT_HOST}" \
      "docker inspect -f '{{.State.Running}}' '${TGT_CONTAINER}' 2>/dev/null || echo NOT_FOUND")
    if   [ "$tgt_running" = "NOT_FOUND" ]; then
      fail "Container '${TGT_CONTAINER}' không tồn tại"; local_err=true
    elif [ "$tgt_running" != "true" ]; then
      fail "Container '${TGT_CONTAINER}' không đang chạy"; local_err=true
    else
      ok "Container '${TGT_CONTAINER}' OK"
    fi
  fi

  if [ "$local_err" = false ]; then
    mysql_remote "$TGT_SSH_PORT" "$TGT_SSH_USER" "$TGT_HOST" \
      "$TGT_DB_MODE" "$TGT_CONTAINER" "$TGT_DB_USER" "$TGT_DB_PASS" "$TGT_DB_NAME" \
      "SELECT 1;" &>/dev/null \
      && ok "DB TARGET OK" \
      || { fail "Không kết nối được DB trên TARGET"; local_err=true; }
  fi

  [ "$local_err" = false ] && break
  echo ""
  confirm_yn "Nhập lại thông tin?" && { echo ""; continue; } || quit
done

# ── BƯỚC 2: Tìm file backup ─────────────────────────────────
step "Tìm file backup trong /root/mariadb-backup/..."

mapfile -t BAK_FILES < <(
  ssh -T -p "$TGT_SSH_PORT" -o StrictHostKeyChecking=no "${TGT_SSH_USER}@${TGT_HOST}" \
    "ls -t /root/mariadb-backup/dump_${TGT_DB_NAME}_*.sql.gz 2>/dev/null" \
    2>/dev/null || true
)

if [ ${#BAK_FILES[@]} -eq 0 ]; then
  warn "Không tìm thấy trong /root/mariadb-backup/ — tìm mở rộng..."
  mapfile -t BAK_FILES < <(
    ssh -T -p "$TGT_SSH_PORT" -o StrictHostKeyChecking=no "${TGT_SSH_USER}@${TGT_HOST}" \
      "find /root /tmp /var/backup 2>/dev/null \
       -name 'dump_${TGT_DB_NAME}_*.sql.gz' \
       -printf '%T@ %p\n' 2>/dev/null | sort -rn | awk '{print \$2}'" \
      2>/dev/null || true
  )
fi

BACKUP_FILE=""

if [ ${#BAK_FILES[@]} -eq 0 ]; then
  fail "Không tìm thấy file backup nào cho DB '${TGT_DB_NAME}'."
  echo ""
  read -rp "  Nhập đường dẫn thủ công (Enter = hủy): " manual_path
  [ -z "$manual_path" ] && quit
  ssh -T -p "$TGT_SSH_PORT" -o StrictHostKeyChecking=no "${TGT_SSH_USER}@${TGT_HOST}" \
    "[ -f '${manual_path}' ]" \
    && BACKUP_FILE="$manual_path" \
    || { fail "File không tồn tại: ${manual_path}"; exit 1; }
else
  echo ""
  echo -e "  ${BOLD}File backup cho DB: ${TGT_DB_NAME}${NC}"
  sep
  printf "  %-4s  %-19s  %-50s  %s\n" "No" "Thời gian" "Tên file" "Size"
  sep
  for i in "${!BAK_FILES[@]}"; do
    fsize=$(ssh -T -p "$TGT_SSH_PORT" -o StrictHostKeyChecking=no \
      "${TGT_SSH_USER}@${TGT_HOST}" \
      "du -sh '${BAK_FILES[$i]}' 2>/dev/null | cut -f1" | tr -d '[:space:]')
    ftime=$(echo "${BAK_FILES[$i]}" | grep -oP '\d{8}_\d{6}' | \
      sed 's/\([0-9]\{4\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)_\([0-9]\{2\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)/\1-\2-\3 \4:\5:\6/' \
      2>/dev/null || echo "unknown")
    if [ "$i" -eq 0 ]; then
      printf "  ${CYAN}%2d)${NC}  ${GREEN}%-19s  %-50s  %s  ← mới nhất${NC}\n" \
        "$((i+1))" "$ftime" "$(basename ${BAK_FILES[$i]})" "$fsize"
    else
      printf "  ${CYAN}%2d)${NC}  ${DIM}%-19s  %-50s  %s${NC}\n" \
        "$((i+1))" "$ftime" "$(basename ${BAK_FILES[$i]})" "$fsize"
    fi
  done
  echo ""
  dim "  Khuyến nghị chọn file mới nhất (số 1)"
  dim "  Nhập 0 để nhập đường dẫn thủ công"
  echo ""

  while true; do
    read -rp "  Chọn [1-${#BAK_FILES[@]}/0]: " choice
    if [ "$choice" = "0" ]; then
      read -rp "  Nhập đường dẫn thủ công (Enter = hủy): " manual_path
      [ -z "$manual_path" ] && quit
      ssh -T -p "$TGT_SSH_PORT" -o StrictHostKeyChecking=no "${TGT_SSH_USER}@${TGT_HOST}" \
        "[ -f '${manual_path}' ]" \
        && BACKUP_FILE="$manual_path" && break \
        || { fail "File không tồn tại: ${manual_path}"; continue; }
    elif [[ "$choice" =~ ^[0-9]+$ ]] && \
         [ "$choice" -ge 1 ] && [ "$choice" -le "${#BAK_FILES[@]}" ]; then
      BACKUP_FILE="${BAK_FILES[$((choice-1))]}"
      if [ "$choice" -ne 1 ]; then
        echo ""
        warn "Đang chọn file KHÔNG phải mới nhất!"
        warn "Mới nhất: $(basename ${BAK_FILES[0]})"
        confirm_yn "Xác nhận chọn file này?" || continue
      fi
      break
    else
      warn "Nhập số từ 1 đến ${#BAK_FILES[@]} hoặc 0."
    fi
  done
fi

BACKUP_FNAME=$(basename "$BACKUP_FILE")
BACKUP_SIZE=$(ssh -T -p "$TGT_SSH_PORT" -o StrictHostKeyChecking=no \
  "${TGT_SSH_USER}@${TGT_HOST}" \
  "du -sh '${BACKUP_FILE}' 2>/dev/null | cut -f1" | tr -d '[:space:]')

# ── BƯỚC 3: Confirm ─────────────────────────────────────────
echo ""
sep
echo -e "  ${BOLD}Xác nhận rollback${NC}"
sep
info "Target : ${TGT_SSH_USER}@${TGT_HOST}:${TGT_SSH_PORT}"
info "DB     : ${TGT_DB_NAME} | $([ "$TGT_DB_MODE" = "1" ] && echo "docker (${TGT_CONTAINER})" || echo "service")"
info "File   : ${BACKUP_FNAME}"
info "Size   : ${BACKUP_SIZE}"
sep
echo ""
warn "DB hiện tại trên TARGET (${TGT_DB_NAME}) sẽ bị XÓA"
warn "và thay bằng nội dung từ file backup trên."
echo ""
confirm_yn "Tiếp tục rollback?" || { echo "  Hủy."; break; }

# ── BƯỚC 4: DROP + CREATE ────────────────────────────────────
step "[1/3] DROP & CREATE DB..."

mysql_remote "$TGT_SSH_PORT" "$TGT_SSH_USER" "$TGT_HOST" \
  "$TGT_DB_MODE" "$TGT_CONTAINER" "$TGT_DB_USER" "$TGT_DB_PASS" "$TGT_DB_NAME" \
  "DROP DATABASE IF EXISTS \`${TGT_DB_NAME}\`; \
   CREATE DATABASE \`${TGT_DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" \
  &>/dev/null \
  && ok "DROP & CREATE DB OK" \
  || {
    fail "Không DROP/CREATE được DB"
    tele_send "❌ <b>ROLLBACK DB — FAIL</b>
Target: <code>${TGT_HOST}</code>  DB: <code>${TGT_DB_NAME}</code>
Lỗi: Không DROP/CREATE được DB
File: <code>${BACKUP_FNAME}</code>
Time: ${START_TIME}"
    exit 1
  }

# ── BƯỚC 5: Import ──────────────────────────────────────────
step "[2/3] Import từ file backup..."

local_import_sh=$(mktemp /tmp/rollback_import_XXXXXX.sh)
cat > "$local_import_sh" << 'SHEOF'
#!/bin/bash
set -euo pipefail
DB_MODE="$1"; CTR="$2"; DB_USER="$3"; DB_PASS="$4"; DB_NAME="$5"; BAK_FILE="$6"
if [ "$DB_MODE" = "1" ]; then
  gunzip -c "$BAK_FILE" | docker exec -i "$CTR" mysql -u"$DB_USER" -p"$DB_PASS" "$DB_NAME"
else
  gunzip -c "$BAK_FILE" | mysql -u"$DB_USER" -p"$DB_PASS" "$DB_NAME"
fi
SHEOF
chmod +x "$local_import_sh"
remote_import_sh="/tmp/rollback_import_$$.sh"
scp -P "$TGT_SSH_PORT" -o StrictHostKeyChecking=no \
  "$local_import_sh" "${TGT_SSH_USER}@${TGT_HOST}:${remote_import_sh}" &>/dev/null
rm -f "$local_import_sh"

ssh -T -p "$TGT_SSH_PORT" -o StrictHostKeyChecking=no "${TGT_SSH_USER}@${TGT_HOST}" \
  "bash ${remote_import_sh} '$TGT_DB_MODE' '$TGT_CONTAINER' \
   '$TGT_DB_USER' '$TGT_DB_PASS' '$TGT_DB_NAME' '${BACKUP_FILE}'; \
   rm -f ${remote_import_sh}" \
  && ok "Import OK" \
  || {
    fail "Import FAIL — kiểm tra thủ công trên TARGET."
    tele_send "❌ <b>ROLLBACK DB — FAIL</b>
Target: <code>${TGT_HOST}</code>  DB: <code>${TGT_DB_NAME}</code>
Lỗi: Import thất bại
File: <code>${BACKUP_FNAME}</code>
Time: ${START_TIME}"
    exit 1
  }

# ── BƯỚC 6: Verify row count ─────────────────────────────────
step "[3/3] Verify row count..."

ROW_COUNT=$(count_rows_on \
  "$TGT_SSH_PORT" "$TGT_SSH_USER" "$TGT_HOST" \
  "$TGT_DB_MODE" "$TGT_CONTAINER" \
  "$TGT_DB_USER" "$TGT_DB_PASS" "$TGT_DB_NAME")

END_TIME=$(date '+%Y-%m-%d %H:%M:%S')

echo ""
sep
info "DB    : ${TGT_DB_NAME}"
info "Rows  : ${ROW_COUNT}"
info "File  : ${BACKUP_FNAME}"
sep

if [ "${ROW_COUNT:-0}" -eq 0 ]; then
  warn "Rows = 0 — DB có thể rỗng hoặc import bị lỗi, kiểm tra lại."
else
  ok "Rollback OK — ${ROW_COUNT} rows"
fi

# ── Kết quả ─────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}  ✅ HOÀN TẤT${NC}"
info "Target : ${TGT_HOST}"
info "DB     : ${TGT_DB_NAME}"
info "Rows   : ${ROW_COUNT}"
info "File   : ${BACKUP_FNAME}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${NC}"

tele_send "✅ <b>ROLLBACK DB — DONE</b>
Target: <code>${TGT_HOST}</code>
DB: <code>${TGT_DB_NAME}</code>
Rows sau rollback: ${ROW_COUNT}
File: <code>${BACKUP_FNAME}</code>
Start: ${START_TIME}
End:   ${END_TIME}"

# ── Hỏi xóa file backup ─────────────────────────────────────
echo ""
if confirm_yn "Xóa file backup sau rollback?"; then
  ssh -T -p "$TGT_SSH_PORT" -o StrictHostKeyChecking=no "${TGT_SSH_USER}@${TGT_HOST}" \
    "rm -f '${BACKUP_FILE}'" &>/dev/null
  ok "Đã xóa: ${BACKUP_FNAME}"
else
  info "Giữ lại: ${BACKUP_FILE}"
fi

# ── Tiếp tục? ────────────────────────────────────────────────
echo ""
confirm_yn "Rollback thêm DB khác?" || break
echo ""

done  # end LOOP CHÍNH

echo ""
