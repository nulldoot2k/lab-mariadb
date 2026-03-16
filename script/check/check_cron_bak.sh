#!/bin/bash
set -euo pipefail

# ============================================================
#  BACKUP + VERIFY + TELEGRAM NOTIFY — MariaDB/MySQL
#  File: scripts/check/check_cron_bak.sh
#
#  Flow mỗi server (song song):
#    1. Dump DB → .sql.gz + MD5 (lưu trên remote server)
#    2. Tạo verify container tạm trên chính remote server
#    3. Restore thử → đếm rows → so sánh range
#    4. Cleanup verify container
#  Sau khi tất cả server xong → 1 Telegram message tổng hợp
# ============================================================

# =========================================
# ⚙️  TELEGRAM CONFIG — chỉnh tại đây trước khi chạy
# =========================================
TELE_TOKEN="your_bot_token_here"
TELE_CHAT_ID="your_chat_id_here"
TELE_THREAD_ID=""   # để trống nếu không dùng thread/topic

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
step() { echo -e "\n${CYAN}$1${NC}"; sep; }

quit() { echo ""; dim "Thoát."; echo ""; exit 0; }

# =========================================
# Biến môi trường
# =========================================
ENV_MODE=""
RUNTIME=""
SERVER_COUNT=0
declare -a SERVERS=() SSH_USERS=() SSH_PORTS=()
CONTAINER=""
MYSQL_HOST="127.0.0.1"
MYSQL_PORT=3306
MYSQL_USER="root"
MYSQL_PASS=""
BACKUP_DIR="/root/mariadb-backup"
VRF_CONTAINER="mariadb-verify-tmp"
VRF_PASS="Verify_$(date +%s)"
INTERVAL_RAW=""
INTERVAL_SEC=0

# Kết quả backup: mảng indexed theo server
declare -a SRV_RESULTS=()

# =========================================
# Helper: đọc password ẩn
# =========================================
read_pass() {
  local prompt="$1" varname="$2" pass="" char=""
  printf "%s" "$prompt"
  while IFS= read -r -s -n1 char; do
    if   [[ -z "$char" ]]; then break
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
# Helper: parse tần suất → giây
# =========================================
parse_interval() {
  local RAW="$1"
  local NUM UNIT
  NUM=$(echo "$RAW" | grep -oP '^\d+' || true)
  UNIT=$(echo "$RAW" | grep -oP '[a-zA-Z]+$' | tr '[:upper:]' '[:lower:]' || true)
  [ -z "$NUM" ] || [ -z "$UNIT" ] && { echo "0"; return 1; }
  case "$UNIT" in
    m|min)  echo $((NUM * 60)) ;;
    h|hour) echo $((NUM * 3600)) ;;
    d|day)  echo $((NUM * 86400)) ;;
    w|week) echo $((NUM * 604800)) ;;
    y|year) echo $((NUM * 31536000)) ;;
    *)      echo "0"; return 1 ;;
  esac
}

interval_label() {
  local RAW="$1"
  local NUM UNIT
  NUM=$(echo "$RAW" | grep -oP '^\d+' || true)
  UNIT=$(echo "$RAW" | grep -oP '[a-zA-Z]+$' | tr '[:upper:]' '[:lower:]' || true)
  case "$UNIT" in
    m|min)  echo "${NUM} phút" ;;
    h|hour) echo "${NUM} giờ" ;;
    d|day)  echo "${NUM} ngày" ;;
    w|week) echo "${NUM} tuần" ;;
    y|year) echo "${NUM} năm" ;;
    *)      echo "$RAW" ;;
  esac
}

# =========================================
# Helper: chạy lệnh SQL trên 1 server — file tạm
# =========================================
ssh_exec() {
  local idx=$1; shift
  ssh -T -p "${SSH_PORTS[$idx]}" -o StrictHostKeyChecking=no \
    "${SSH_USERS[$idx]}@${SERVERS[$idx]}" "$@"
}

mysql_q_remote() {
  # mysql_q_remote idx query → stdout
  local idx=$1; local query=$2
  local sf; sf=$(mktemp /tmp/bak_sql_XXXXXX)
  echo "$query" > "$sf"
  if [ "$RUNTIME" = "docker" ]; then
    ssh_exec "$idx" \
      "docker exec -i $CONTAINER mysql -u\"$MYSQL_USER\" -p\"$MYSQL_PASS\" -N 2>/dev/null" \
      < "$sf"
  else
    ssh_exec "$idx" \
      "mysql -h\"$MYSQL_HOST\" -P\"$MYSQL_PORT\" -u\"$MYSQL_USER\" -p\"$MYSQL_PASS\" -N 2>/dev/null" \
      < "$sf"
  fi
  rm -f "$sf"
}

mysql_q_local() {
  # mysql_q_local query → stdout (ENV_MODE=local)
  local query=$1
  local sf; sf=$(mktemp /tmp/bak_sql_XXXXXX)
  echo "$query" > "$sf"
  if [ "$RUNTIME" = "docker" ]; then
    docker exec -i "$CONTAINER" \
      mysql -u"$MYSQL_USER" -p"$MYSQL_PASS" -N 2>/dev/null < "$sf"
  else
    mysql -h"$MYSQL_HOST" -P"$MYSQL_PORT" \
      -u"$MYSQL_USER" -p"$MYSQL_PASS" -N 2>/dev/null < "$sf"
  fi
  rm -f "$sf"
}

mysql_q_on() {
  local idx=$1; local query=$2
  if [ "$ENV_MODE" = "local" ]; then
    mysql_q_local "$query"
  else
    mysql_q_remote "$idx" "$query"
  fi
}

# =========================================
# BƯỚC 1: Chọn môi trường
# =========================================
setup_env() {
  while true; do
    echo ""
    echo -e "  ${BOLD}Môi trường thực thi${NC}"
    sep
    echo -e "  ${CYAN}1)${NC}  Local   — DB đang chạy trên máy này"
    echo -e "  ${CYAN}2)${NC}  Server  — DB đang chạy trên server remote"
    echo -e "  ${CYAN}q)${NC}  Thoát"
    echo ""
    read -rp "  Chọn [1/2/q]: " choice
    case "$choice" in
      1)
        ENV_MODE="local"
        SERVER_COUNT=1
        SERVERS=("localhost"); SSH_USERS=(""); SSH_PORTS=("")
        return 0 ;;
      2)
        ENV_MODE="server"
        echo ""
        read -rp "  Số lượng server: " count
        if ! [[ "$count" =~ ^[0-9]+$ ]] || [ "$count" -lt 1 ]; then
          warn "Nhập số >= 1."; continue
        fi
        SERVER_COUNT=$count
        SERVERS=(); SSH_USERS=(); SSH_PORTS=()
        echo ""
        for i in $(seq 1 $SERVER_COUNT); do
          echo -e "  ${CYAN}── Server #${i} ──${NC}"
          read -rp "    Host IP / domain : " host
          read -rp "    SSH User (root)  : " input; user=${input:-root}
          read -rp "    SSH Port (22)    : " input; port=${input:-22}
          SERVERS+=("$host"); SSH_USERS+=("$user"); SSH_PORTS+=("$port")
          echo ""
        done
        if ! check_ssh; then return 1; fi
        return 0 ;;
      q|Q) quit ;;
      *) warn "Nhập 1, 2 hoặc q." ;;
    esac
  done
}

check_ssh() {
  echo ""
  echo -e "  Kiểm tra SSH ${SERVER_COUNT} server cùng lúc..."
  local tmp; tmp=$(mktemp -d); local pids=()
  for i in $(seq 0 $((SERVER_COUNT - 1))); do
    ( ssh -p "${SSH_PORTS[$i]}" -o ConnectTimeout=5 -o BatchMode=yes \
        -o StrictHostKeyChecking=no "${SSH_USERS[$i]}@${SERVERS[$i]}" \
        "echo ok" &>/dev/null \
        && echo "ok" > "${tmp}/r_${i}" || echo "fail" > "${tmp}/r_${i}" ) &
    pids+=($!)
  done
  for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done
  echo ""
  local all_ok=true
  for i in $(seq 0 $((SERVER_COUNT - 1))); do
    local r; r=$(cat "${tmp}/r_${i}" 2>/dev/null || echo "fail")
    [ "$r" = "ok" ] \
      && ok "${SSH_USERS[$i]}@${SERVERS[$i]}:${SSH_PORTS[$i]}" \
      || { fail "${SSH_USERS[$i]}@${SERVERS[$i]}:${SSH_PORTS[$i]} — không kết nối được"; all_ok=false; }
  done
  rm -rf "$tmp"
  [ "$all_ok" = true ] && return 0 || { echo ""; warn "Một số server không SSH được."; return 1; }
}

# =========================================
# BƯỚC 2: Chọn runtime
# =========================================
setup_runtime() {
  while true; do
    echo ""
    echo -e "  ${BOLD}Loại runtime${NC}"
    sep
    echo -e "  ${CYAN}1)${NC}  Docker container"
    echo -e "  ${CYAN}2)${NC}  Service (systemd / native)"
    echo -e "  ${CYAN}b)${NC}  Quay lại"
    echo ""
    read -rp "  Chọn [1/2/b]: " choice
    case "$choice" in
      1)
        RUNTIME="docker"
        echo ""
        read -rp "  Tên container (mariadb-104) : " input
        CONTAINER=${input:-mariadb-104}
        read -rp "  MySQL User   (root)        : " input; MYSQL_USER=${input:-root}
        read_pass "  MySQL Pass                 : " MYSQL_PASS
        if check_runtime; then return 0; fi ;;
      2)
        RUNTIME="service"
        echo ""
        read -rp "  MariaDB Host (127.0.0.1) : " input; MYSQL_HOST=${input:-127.0.0.1}
        read -rp "  MariaDB Port (3306)      : " input; MYSQL_PORT=${input:-3306}
        read -rp "  MySQL User   (root)      : " input; MYSQL_USER=${input:-root}
        read_pass "  MySQL Pass               : " MYSQL_PASS
        if check_runtime; then return 0; fi ;;
      b|B) return 1 ;;
      *) warn "Nhập 1, 2 hoặc b." ;;
    esac
  done
}

check_runtime() {
  echo ""
  local check_count=$SERVER_COUNT
  [ "$ENV_MODE" = "local" ] && check_count=1
  local tmp; tmp=$(mktemp -d); local pids=()
  echo -e "  Kiểm tra runtime ${check_count} server cùng lúc..."
  for i in $(seq 0 $((check_count - 1))); do
    (
      if [ "$RUNTIME" = "docker" ]; then
        local running
        if [ "$ENV_MODE" = "server" ]; then
          running=$(ssh_exec "$i" \
            "docker inspect -f '{{.State.Running}}' $CONTAINER 2>/dev/null || echo NOT_FOUND")
        else
          running=$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || echo "NOT_FOUND")
        fi
        [ "$running" = "NOT_FOUND" ] && { echo "fail:container '$CONTAINER' không tồn tại" > "${tmp}/r_${i}"; exit 0; }
        [ "$running" != "true" ]     && { echo "fail:container '$CONTAINER' không đang chạy" > "${tmp}/r_${i}"; exit 0; }
      fi
      if ! mysql_q_on "$i" "SELECT 1;" &>/dev/null; then
        echo "fail:không kết nối được MariaDB" > "${tmp}/r_${i}"; exit 0
      fi
      echo "ok" > "${tmp}/r_${i}"
    ) &
    pids+=($!)
  done
  for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done
  echo ""
  local all_ok=true
  for i in $(seq 0 $((check_count - 1))); do
    local r; r=$(cat "${tmp}/r_${i}" 2>/dev/null || echo "fail:không có kết quả")
    local label; [ "$ENV_MODE" = "server" ] && label="${SERVERS[$i]}" || label="local"
    [ "$r" = "ok" ] && ok "$label" || { fail "$label — ${r#fail:}"; all_ok=false; }
  done
  rm -rf "$tmp"
  [ "$all_ok" = true ] && return 0 || return 1
}

# =========================================
# BƯỚC 3: Chọn DB — lần lượt từng server
# SERVER_SELECTED_DBS[i] = "db1|db2|..." (pipe-separated)
# =========================================
select_dbs() {
  local run_count=$SERVER_COUNT
  [ "$ENV_MODE" = "local" ] && run_count=1
  declare -g -a SERVER_SELECTED_DBS=()

  for i in $(seq 0 $((run_count - 1))); do
    local label; [ "$ENV_MODE" = "server" ] && label="${SERVERS[$i]}" || label="local"

    mapfile -t DBS_ON_SERVER < <(
      mysql_q_on "$i" "SELECT schema_name
               FROM information_schema.schemata
               WHERE schema_name NOT IN (
                 'information_schema','performance_schema',
                 'mysql','sys','innodb'
               )
               ORDER BY schema_name;" 2>/dev/null
    )

    if [ ${#DBS_ON_SERVER[@]} -eq 0 ]; then
      warn "Server ${label} không có DB nào — bỏ qua."
      SERVER_SELECTED_DBS+=(""); continue
    fi

    while true; do
      echo ""
      echo -e "  ${BOLD}[Server: ${CYAN}${label}${NC}${BOLD}]${NC}  Chọn DB để backup"
      sep
      for j in "${!DBS_ON_SERVER[@]}"; do
        printf "  ${CYAN}%2d)${NC}  %s\n" "$((j+1))" "${DBS_ON_SERVER[$j]}"
      done
      echo -e "  ${CYAN} 0)${NC}  Tất cả"
      echo ""
      dim "  Chọn 1 hoặc nhiều, cách nhau bởi dấu phẩy. Vd: 1,2"
      dim "  q) Thoát"
      echo ""
      read -rp "  Nhập [0-${#DBS_ON_SERVER[@]}/q]: " input

      case "${input// /}" in
        q|Q) quit ;;
        0)
          local joined; joined=$(printf '%s|' "${DBS_ON_SERVER[@]}")
          SERVER_SELECTED_DBS+=("${joined%|}"); break ;;
      esac

      IFS=',' read -ra choices <<< "${input// /}"
      local picked=() valid=1
      for choice in "${choices[@]}"; do
        if [[ "$choice" =~ ^[0-9]+$ ]] && \
           [ "$choice" -ge 1 ] && [ "$choice" -le "${#DBS_ON_SERVER[@]}" ]; then
          picked+=("${DBS_ON_SERVER[$((choice-1))]}")
        else
          warn "'${choice}' không hợp lệ."; valid=0; break
        fi
      done
      [ "$valid" -eq 0 ] && continue
      mapfile -t picked < <(printf '%s\n' "${picked[@]}" | sort -u)
      if [ ${#picked[@]} -gt 0 ]; then
        local joined; joined=$(printf '%s|' "${picked[@]}")
        SERVER_SELECTED_DBS+=("${joined%|}"); break
      fi
    done
  done
}

# =========================================
# BƯỚC 4: Cấu hình backup
# =========================================
setup_config() {
  echo ""
  echo -e "  ${BOLD}Cấu hình backup${NC}"
  sep
  read -rp "  Thư mục backup trên server (/root/mariadb-backup) : " input
  BACKUP_DIR=${input:-/root/mariadb-backup}

  read -rp "  Tên verify container (mariadb-verify-tmp)         : " input
  VRF_CONTAINER=${input:-mariadb-verify-tmp}

  echo ""
  echo -e "  ${BOLD}Tần suất backup${NC}"
  dim "  Định dạng: 30m | 6h | 1d | 7d | 2w | 1y  (để trống = 1 lần)"
  echo ""
  read -rp "  Tần suất (Enter = 1 lần): " INTERVAL_RAW

  INTERVAL_SEC=0
  if [ -n "$INTERVAL_RAW" ]; then
    INTERVAL_SEC=$(parse_interval "$INTERVAL_RAW" 2>/dev/null || echo 0)
    if [ "${INTERVAL_SEC:-0}" -le 0 ]; then
      warn "Định dạng không hợp lệ — sẽ chạy 1 lần."
      INTERVAL_RAW=""; INTERVAL_SEC=0
    fi
  fi
}

# =========================================
# Telegram: gửi message
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
# Đếm rows của 1 DB trên source (file tạm)
# =========================================
count_rows_src() {
  local idx=$1; local DB=$2
  # Chạy shell script mini trực tiếp trên remote — tránh escape/truncate
  local sh; sh=$(mktemp /tmp/bak_cnt_XXXXXX.sh)
  cat > "$sh" << 'SHEOF'
#!/bin/bash
# Args: RUNTIME CONTAINER MYSQL_USER MYSQL_PASS MYSQL_HOST MYSQL_PORT DB
RUNTIME="$1"; CTR="$2"; USR="$3"; PASS="$4"
HOST="$5"; PORT="$6"; DB="$7"
mysql_cmd() {
  if [ "$RUNTIME" = "docker" ]; then
    docker exec -i "$CTR" mysql -u"$USR" -p"$PASS" -N 2>/dev/null
  else
    mysql -h"$HOST" -P"$PORT" -u"$USR" -p"$PASS" -N 2>/dev/null
  fi
}
TABLES=$(echo "SELECT table_name FROM information_schema.tables WHERE table_schema='$DB' AND table_type='BASE TABLE';" | mysql_cmd)
total=0
while IFS= read -r tbl; do
  [ -z "$tbl" ] && continue
  cnt=$(echo "SELECT COUNT(*) FROM \`$DB\`.\`$tbl\`;" | mysql_cmd | tr -d '[:space:]')
  total=$(( total + ${cnt:-0} ))
done <<< "$TABLES"
echo $total
SHEOF
  chmod +x "$sh"

  local result
  if [ "$ENV_MODE" = "server" ]; then
    local remote_sh="/tmp/bak_cnt_${idx}_$$.sh"
    scp -P "${SSH_PORTS[$idx]}" -o StrictHostKeyChecking=no \
      "$sh" "${SSH_USERS[$idx]}@${SERVERS[$idx]}:${remote_sh}" &>/dev/null
    result=$(ssh_exec "$idx" \
      "bash ${remote_sh} '$RUNTIME' '$CONTAINER' '$MYSQL_USER' '$MYSQL_PASS' \
       '$MYSQL_HOST' '$MYSQL_PORT' '$DB' 2>/dev/null; rm -f ${remote_sh}" \
      | tr -d '[:space:]')
  else
    result=$(bash "$sh" "$RUNTIME" "$CONTAINER" "$MYSQL_USER" "$MYSQL_PASS" \
      "$MYSQL_HOST" "$MYSQL_PORT" "$DB" 2>/dev/null | tr -d '[:space:]')
  fi
  rm -f "$sh"
  echo "${result:-0}"
}


# =========================================
# Setup verify container trên 1 server
# =========================================
setup_vrf_container_on() {
  local idx=$1; local vrf_ctr=$2
  local label; [ "$ENV_MODE" = "server" ] && label="${SERVERS[$idx]}" || label="local"

  # Lấy image từ source container
  local vrf_image="mariadb:10.4"
  if [ "$RUNTIME" = "docker" ]; then
    if [ "$ENV_MODE" = "server" ]; then
      vrf_image=$(ssh_exec "$idx"         "docker inspect -f '{{.Config.Image}}' $CONTAINER 2>/dev/null || echo mariadb:10.4"         | tr -d '[:space:]')
    else
      vrf_image=$(docker inspect -f '{{.Config.Image}}' "$CONTAINER" 2>/dev/null || echo "mariadb:10.4")
    fi
  fi

  info "[${label}] Tạo verify container '${vrf_ctr}' (image: ${vrf_image})..."

  if [ "$ENV_MODE" = "server" ]; then
    ssh_exec "$idx" "docker rm -f ${vrf_ctr} 2>/dev/null || true" &>/dev/null
    ssh_exec "$idx"       "docker run -d --name ${vrf_ctr}        -e MYSQL_ROOT_PASSWORD="${VRF_PASS}"        -e MYSQL_ROOT_HOST="%"        ${vrf_image}        --character-set-server=utf8mb4        --collation-server=utf8mb4_unicode_ci        > /dev/null 2>&1" &>/dev/null       || { fail "[${label}] Không tạo được verify container"; return 1; }
  else
    docker rm -f "$vrf_ctr" 2>/dev/null || true
    docker run -d --name "$vrf_ctr"       -e MYSQL_ROOT_PASSWORD="$VRF_PASS"       -e MYSQL_ROOT_HOST="%"       "$vrf_image"       --character-set-server=utf8mb4       --collation-server=utf8mb4_unicode_ci       > /dev/null 2>&1       || { fail "[${label}] Không tạo được verify container"; return 1; }
  fi

  # Đợi ready
  local retry=0
  while [ $retry -lt 30 ]; do
    if [ "$ENV_MODE" = "server" ]; then
      ssh_exec "$idx"         "docker exec ${vrf_ctr} mysql -uroot -p"${VRF_PASS}" -e 'SELECT 1;' > /dev/null 2>&1"         && { ok "[${label}] Verify container ready (${retry}s)"; return 0; }
    else
      docker exec "$vrf_ctr" mysql -uroot -p"$VRF_PASS"         -e "SELECT 1;" > /dev/null 2>&1         && { ok "[${label}] Verify container ready (${retry}s)"; return 0; }
    fi
    retry=$((retry+1)); sleep 1
  done

  fail "[${label}] Verify container timeout"; return 1
}

# =========================================
# Cleanup verify container trên 1 server
# =========================================
_cleanup_vrf() {
  local idx=$1; local ctr=$2
  if [ "$ENV_MODE" = "server" ]; then
    ssh_exec "$idx"       "docker stop ${ctr} 2>/dev/null; docker rm ${ctr} 2>/dev/null || true"       &>/dev/null || true
  else
    docker stop "$ctr" 2>/dev/null || true
    docker rm   "$ctr" 2>/dev/null || true
  fi
}

# =========================================
# Backup 1 DB — dùng verify container đã có sẵn
# =========================================
backup_one_on() {
  local idx=$1; local DB=$2; local vrf_ctr=$3; local result_file=$4
  local label; [ "$ENV_MODE" = "server" ] && label="${SERVERS[$idx]}" || label="local"
  local TS; TS=$(date '+%Y%m%d_%H%M%S')
  local dump_fname="backup_${DB}_${TS}.sql.gz"
  local dump_path="${BACKUP_DIR}/${dump_fname}"
  local vrf_db="_verify_${TS}"
  local rows_pre=0 rows_post=0 rows_vrf=0 file_size="—"
  local status="OK" msg=""

  echo -e "  ${BOLD}[${label}] DB: ${DB}${NC}"

  # ── Tạo thư mục backup ──
  if [ "$ENV_MODE" = "server" ]; then
    ssh_exec "$idx" "mkdir -p ${BACKUP_DIR}" &>/dev/null       || { echo "FAIL|${DB}|${label}|Không tạo được thư mục backup|0|0|0|—|—" > "$result_file"; return 1; }
  else
    mkdir -p "${BACKUP_DIR}"
  fi

  # ── a. Đếm rows trước dump ──
  rows_pre=$(count_rows_src "$idx" "$DB" 2>/dev/null || echo 0)
  info "[${label}] ${DB} — pre-dump rows: ${rows_pre}"

  # ── b. Dump ──
  info "[${label}] ${DB} — đang dump..."
  local dump_ok=true
  if [ "$ENV_MODE" = "server" ]; then
    if [ "$RUNTIME" = "docker" ]; then
      ssh_exec "$idx"         "docker exec $CONTAINER mysqldump --single-transaction --routines --triggers --opt          -u"$MYSQL_USER" -p"$MYSQL_PASS" "$DB" 2>/dev/null | gzip > "${dump_path}""         || dump_ok=false
    else
      ssh_exec "$idx"         "mysqldump --single-transaction --routines --triggers --opt          -u"$MYSQL_USER" -p"$MYSQL_PASS" "$DB" 2>/dev/null | gzip > "${dump_path}""         || dump_ok=false
    fi
  else
    if [ "$RUNTIME" = "docker" ]; then
      docker exec "$CONTAINER" mysqldump --single-transaction --routines --triggers --opt         -u"$MYSQL_USER" -p"$MYSQL_PASS" "$DB" 2>/dev/null | gzip > "$dump_path" || dump_ok=false
    else
      mysqldump --single-transaction --routines --triggers --opt         -u"$MYSQL_USER" -p"$MYSQL_PASS" "$DB" 2>/dev/null | gzip > "$dump_path" || dump_ok=false
    fi
  fi

  if [ "$dump_ok" = false ]; then
    echo "FAIL|${DB}|${label}|Dump thất bại|${rows_pre}|0|0|—|—" > "$result_file"; return 1
  fi

  if [ "$ENV_MODE" = "server" ]; then
    file_size=$(ssh_exec "$idx" "du -sh "${dump_path}" 2>/dev/null | cut -f1" | tr -d '[:space:]')
    ssh_exec "$idx" "md5sum "${dump_path}" > "${dump_path}.md5"" &>/dev/null
    local md5_ok
    md5_ok=$(ssh_exec "$idx"       "cd "${BACKUP_DIR}" && md5sum -c "${dump_fname}.md5" --quiet 2>/dev/null && echo ok || echo fail")
  else
    file_size=$(du -sh "$dump_path" 2>/dev/null | cut -f1 | tr -d '[:space:]')
    md5sum "$dump_path" > "${dump_path}.md5"
    local md5_ok
    md5_ok=$(cd "${BACKUP_DIR}" && md5sum -c "${dump_fname}.md5" --quiet 2>/dev/null && echo ok || echo fail)
  fi

  if [ "${md5_ok:-fail}" != "ok" ]; then
    echo "FAIL|${DB}|${label}|MD5 không khớp|${rows_pre}|0|0|${file_size}|${dump_fname}" > "$result_file"
    return 1
  fi
  ok "[${label}] ${DB} — dump OK (${file_size}) → ${dump_fname}"

  # ── c. Đếm rows sau dump ──
  rows_post=$(count_rows_src "$idx" "$DB" 2>/dev/null || echo 0)

  # ── d. Tạo DB tạm trên verify container ──
  if [ "$ENV_MODE" = "server" ]; then
    ssh_exec "$idx"       "docker exec ${vrf_ctr} mysql -uroot -p"${VRF_PASS}"        -e 'CREATE DATABASE \`${vrf_db}\` CHARACTER SET utf8mb4;' 2>/dev/null"       || { echo "FAIL|${DB}|${label}|Không tạo DB tạm trên verify container|${rows_pre}|${rows_post}|0|${file_size}|${dump_fname}" > "$result_file"; return 1; }
  else
    docker exec "$vrf_ctr" mysql -uroot -p"$VRF_PASS"       -e "CREATE DATABASE \`${vrf_db}\` CHARACTER SET utf8mb4;" 2>/dev/null       || { echo "FAIL|${DB}|${label}|Không tạo DB tạm trên verify container|${rows_pre}|${rows_post}|0|${file_size}|${dump_fname}" > "$result_file"; return 1; }
  fi

  # ── e. Restore thử ──
  info "[${label}] ${DB} — restore thử..."
  local restore_ok=true
  if [ "$ENV_MODE" = "server" ]; then
    ssh_exec "$idx"       "gunzip -c "${dump_path}" | docker exec -i ${vrf_ctr}        mysql -uroot -p"${VRF_PASS}" "${vrf_db}" 2>/dev/null"       || restore_ok=false
  else
    gunzip -c "$dump_path" | docker exec -i "$vrf_ctr"       mysql -uroot -p"$VRF_PASS" "$vrf_db" 2>/dev/null || restore_ok=false
  fi

  if [ "$restore_ok" = false ]; then
    # Drop DB tạm
    if [ "$ENV_MODE" = "server" ]; then
      ssh_exec "$idx"         "docker exec ${vrf_ctr} mysql -uroot -p"${VRF_PASS}"          -e 'DROP DATABASE IF EXISTS \`${vrf_db}\`;' 2>/dev/null || true" &>/dev/null
    else
      docker exec "$vrf_ctr" mysql -uroot -p"$VRF_PASS"         -e "DROP DATABASE IF EXISTS \`${vrf_db}\`;" 2>/dev/null || true
    fi
    echo "FAIL|${DB}|${label}|Restore thử thất bại|${rows_pre}|${rows_post}|0|${file_size}|${dump_fname}" > "$result_file"
    return 1
  fi
  ok "[${label}] ${DB} — restore thử OK"

  # ── f. Đếm rows verify ──
  local sh; sh=$(mktemp /tmp/bak_vrf_cnt_XXXXXX.sh)
  printf '%s\n' \
    '#!/bin/bash' \
    'VRF_CTR="$1"; VRF_PASS="$2"; VRF_DB="$3"' \
    'TABLES=$(docker exec "$VRF_CTR" mysql -uroot -p"$VRF_PASS" -N -e "SELECT table_name FROM information_schema.tables WHERE table_schema='"'"'$VRF_DB'"'"' AND table_type='"'"'BASE TABLE'"'"';" 2>/dev/null)' \
    'total=0' \
    'while IFS= read -r tbl; do' \
    '  [ -z "$tbl" ] && continue' \
    '  cnt=$(docker exec "$VRF_CTR" mysql -uroot -p"$VRF_PASS" -N -e "SELECT COUNT(*) FROM \`$VRF_DB\`.\`$tbl\`;" 2>/dev/null | tr -d "[:space:]")' \
    '  total=$(( total + ${cnt:-0} ))' \
    'done <<< "$TABLES"' \
    'echo $total' > "$sh"
  chmod +x "$sh"

  if [ "$ENV_MODE" = "server" ]; then
    local remote_sh="/tmp/bak_vrf_cnt_${idx}_$$.sh"
    scp -P "${SSH_PORTS[$idx]}" -o StrictHostKeyChecking=no \
      "$sh" "${SSH_USERS[$idx]}@${SERVERS[$idx]}:${remote_sh}" &>/dev/null
    rows_vrf=$(ssh_exec "$idx" \
      "bash ${remote_sh} '${vrf_ctr}' '${VRF_PASS}' '${vrf_db}'; rm -f ${remote_sh}" \
      2>/dev/null | tr -d '[:space:]')
  else
    rows_vrf=$(bash "$sh" "$vrf_ctr" "$VRF_PASS" "$vrf_db" 2>/dev/null | tr -d '[:space:]')
  fi
  rm -f "$sh"
  rows_vrf=${rows_vrf:-0}
  # ── g. Drop DB tạm ──
  if [ "$ENV_MODE" = "server" ]; then
    ssh_exec "$idx"       "docker exec ${vrf_ctr} mysql -uroot -p"${VRF_PASS}"        -e 'DROP DATABASE IF EXISTS \`${vrf_db}\`;' 2>/dev/null || true" &>/dev/null
  else
    docker exec "$vrf_ctr" mysql -uroot -p"$VRF_PASS"       -e "DROP DATABASE IF EXISTS \`${vrf_db}\`;" 2>/dev/null || true
  fi

  # ── h. Verify range ──
  info "[${label}] ${DB} — rows: pre=${rows_pre}  post=${rows_post}  restored=${rows_vrf}"
  info "[${label}] ${DB} — valid range: ${rows_pre} ≤ restored ≤ ${rows_post}"

  if [ "${rows_vrf}" -lt "${rows_pre}" ] || [ "${rows_vrf}" -gt "${rows_post}" ]; then
    msg="Row count ngoài range (pre:${rows_pre} ≤ restored:${rows_vrf} ≤ post:${rows_post})"
    fail "[${label}] ${DB} — ${msg}"
    echo "FAIL|${DB}|${label}|${msg}|${rows_pre}|${rows_post}|${rows_vrf}|${file_size}|${dump_fname}" > "$result_file"
    return 1
  fi

  ok "[${label}] ${DB} — verify OK. restored=${rows_vrf} trong range [${rows_pre}, ${rows_post}]"
  echo "OK|${DB}|${label}||${rows_pre}|${rows_post}|${rows_vrf}|${file_size}|${dump_fname}" > "$result_file"
}

# =========================================
# Chạy 1 cycle: server song song, DB tuần tự
# =========================================
run_cycle() {
  local cycle=$1
  local run_count=$SERVER_COUNT
  [ "$ENV_MODE" = "local" ] && run_count=1
  local cycle_start; cycle_start=$(date '+%Y-%m-%d %H:%M:%S')

  echo ""
  echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}  CYCLE #${cycle}  —  ${cycle_start}${NC}"
  echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${NC}"

  local tmp_dir; tmp_dir=$(mktemp -d)
  local srv_pids=()

  # Mỗi server chạy trong 1 subshell song song
  for i in $(seq 0 $((run_count - 1))); do
    local db_str="${SERVER_SELECTED_DBS[$i]:-}"
    [ -z "$db_str" ] && continue

    (
      local label; [ "$ENV_MODE" = "server" ] && label="${SERVERS[$i]}" || label="local"
      local vrf_ctr="${VRF_CONTAINER}_${i}"
      IFS='|' read -ra DBS <<< "$db_str"

      # Setup 1 verify container cho server này
      if ! setup_vrf_container_on "$i" "$vrf_ctr"; then
        # Ghi fail cho tất cả DB của server này
        for DB in "${DBS[@]}"; do
          echo "FAIL|${DB}|${label}|Không tạo được verify container|0|0|0|—|—"             > "${tmp_dir}/r_${i}_${DB}"
        done
        exit 1
      fi

      # Backup từng DB tuần tự dùng chung verify container
      for DB in "${DBS[@]}"; do
        local rf="${tmp_dir}/r_${i}_${DB}"
        backup_one_on "$i" "$DB" "$vrf_ctr" "$rf"
      done

      # Cleanup verify container sau khi xong tất cả DB
      _cleanup_vrf "$i" "$vrf_ctr"
      info "[${label}] Đã xóa verify container '${vrf_ctr}'."
    ) &
    srv_pids+=($!)
  done

  for pid in "${srv_pids[@]}"; do wait "$pid" 2>/dev/null || true; done

  local cycle_end; cycle_end=$(date '+%Y-%m-%d %H:%M:%S')
  local count_ok=0 count_fail=0 tele_detail=""

  echo ""
  echo "  ════════════════════════════════════════════════════"
  echo -e "  ${BOLD}KẾT QUẢ — Cycle #${cycle}${NC}"
  echo "  ════════════════════════════════════════════════════"
  echo "  Bắt đầu  : ${cycle_start}"
  echo "  Kết thúc : ${cycle_end}"
  echo ""

  for rf in "${tmp_dir}"/r_*; do
    [ -f "$rf" ] || continue
    local last_line; last_line=$(grep '|' "$rf" | tail -1)
    [ -z "$last_line" ] && continue
    IFS='|' read -r STATUS DB LABEL MSG ROWS_PRE ROWS_POST ROWS_VRF FILE_SIZE FNAME <<< "$last_line"

    if [ "$STATUS" = "OK" ]; then
      count_ok=$((count_ok+1))
      ok "[${LABEL}] ${DB}  ${FILE_SIZE}  restored=${ROWS_VRF}"
      tele_detail+="
✅ <b>${LABEL}</b> — <code>${DB}</code>
   ${FILE_SIZE}  |  rows: pre=${ROWS_PRE}  restored=${ROWS_VRF}  post=${ROWS_POST}
   File: <code>${FNAME}</code>"
    else
      count_fail=$((count_fail+1))
      fail "[${LABEL}] ${DB} — ${MSG}"
      tele_detail+="
❌ <b>${LABEL}</b> — <code>${DB}</code>
   Lỗi: ${MSG}
   rows: pre=${ROWS_PRE}  restored=${ROWS_VRF}  post=${ROWS_POST}"
    fi
  done
  rm -rf "$tmp_dir"

  local total=$((count_ok + count_fail))
  echo ""
  echo "  Thành công : ${count_ok} / ${total}"
  [ "$count_fail" -gt 0 ] && echo "  Thất bại   : ${count_fail} / ${total}"
  echo "  ════════════════════════════════════════════════════"

  local icon="✅"; [ "$count_fail" -gt 0 ] && icon="❌"
  local status_label="DONE"; [ "$count_fail" -gt 0 ] && status_label="FAIL"
  local cycle_label=""
  [ "$INTERVAL_SEC" -gt 0 ] && cycle_label="  Cycle #${cycle} / every $(interval_label "$INTERVAL_RAW")"

  tele_send "${icon} <b>BACKUP - Check BACKUP DB  ${status_label}</b>${cycle_label}
${tele_detail}

Backup dir: <code>${BACKUP_DIR}</code>
Start: ${cycle_start}
End:   ${cycle_end}
OK: ${count_ok}/${total}  Fail: ${count_fail}/${total}"

  [ "$count_fail" -eq 0 ]     && ok "Cycle #${cycle} hoàn tất. Đã notify Telegram."     || warn "Cycle #${cycle} có ${count_fail} DB lỗi. Đã notify Telegram."
}

# =========================================
# MAIN
# =========================================
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}  BACKUP + VERIFY + NOTIFY — MariaDB/MySQL${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
echo ""

# Bước 1: Môi trường
while true; do setup_env && break; done

# Bước 2: Runtime (b → quay lại env)
while true; do
  setup_runtime && break
  while true; do setup_env && break; done
done

# Bước 3: Chọn DB
select_dbs

# Bước 4: Cấu hình
setup_config

# Preview
echo ""
sep
if [ "$ENV_MODE" = "local" ]; then
  info "Môi trường  : Local"
else
  for i in $(seq 0 $((SERVER_COUNT - 1))); do
    info "Server #$((i+1))   : ${SSH_USERS[$i]}@${SERVERS[$i]}:${SSH_PORTS[$i]}"
    db_str="${SERVER_SELECTED_DBS[$i]:-}"
    if [ -n "$db_str" ]; then
      IFS='|' read -ra DBS <<< "$db_str"
      for DB in "${DBS[@]}"; do info "  DB        : ${DB}"; done
    fi
  done
fi
[ "$RUNTIME" = "docker" ] \
  && info "Runtime     : Docker (container: $CONTAINER)" \
  || info "Runtime     : Service (${MYSQL_HOST}:${MYSQL_PORT})"
info "Backup dir  : ${BACKUP_DIR}"
info "Verify CTR  : ${VRF_CONTAINER}"
[ "$INTERVAL_SEC" -gt 0 ] \
  && info "Tần suất    : mỗi $(interval_label "$INTERVAL_RAW")" \
  || info "Tần suất    : 1 lần"
[ "$TELE_TOKEN" != "your_bot_token_here" ] \
  && info "Telegram    : chat=${TELE_CHAT_ID}" \
  || info "Telegram    : chưa config (bỏ qua notify)"
sep

echo ""
read -rp "  Tiếp tục? (yes/no): " confirm
[[ "$confirm" == "yes" ]] || quit

# =========================================
# Scheduler loop
# =========================================
CYCLE=0
[ "$INTERVAL_SEC" -gt 0 ] && ok "Chế độ lặp: mỗi $(interval_label "$INTERVAL_RAW"). Nhấn Ctrl+C để dừng."

while true; do
  CYCLE=$((CYCLE+1))
  run_cycle "$CYCLE"

  [ "$INTERVAL_SEC" -le 0 ] && break

  next_ts=$(date -d "+${INTERVAL_SEC} seconds" '+%Y-%m-%d %H:%M:%S' 2>/dev/null \
    || date -v "+${INTERVAL_SEC}S" '+%Y-%m-%d %H:%M:%S' 2>/dev/null \
    || echo "N/A")
  echo ""
  info "Lần tiếp theo: ${next_ts}  (sau $(interval_label "$INTERVAL_RAW"))"
  info "Nhấn Ctrl+C để dừng."
  sleep "$INTERVAL_SEC"
done
