#!/bin/bash

# ============================================================
#  MOODLE DB CHECKER
#  Chạy : bash check_moodle_db.sh
#  Mode : fast (mặc định) | exact | verify
#  Override: MODE=exact bash check_moodle_db.sh
# ============================================================

MODE=${MODE:-fast}

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

quit() {
  echo ""
  dim "Thoát."
  echo ""
  exit 0
}

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
MYSQL_PASS="rootpassword"

# =========================================
# Helper: mysql (table output) — dùng file tạm
# =========================================
mysql_table_on() {
  local idx=$1
  local sql_file
  sql_file=$(mktemp /tmp/moodle_sql_XXXXXX)
  cat > "$sql_file"

  if [ "$RUNTIME" = "docker" ]; then
    if [ "$ENV_MODE" = "server" ]; then
      ssh -T -p "${SSH_PORTS[$idx]}" -o StrictHostKeyChecking=no \
        "${SSH_USERS[$idx]}@${SERVERS[$idx]}" \
        "docker exec -i $CONTAINER mysql -u\"$MYSQL_USER\" -p\"$MYSQL_PASS\" --table 2>/dev/null" \
        < "$sql_file"
    else
      docker exec -i "$CONTAINER" \
        mysql -u"$MYSQL_USER" -p"$MYSQL_PASS" --table 2>/dev/null < "$sql_file"
    fi
  else
    if [ "$ENV_MODE" = "server" ]; then
      ssh -T -p "${SSH_PORTS[$idx]}" -o StrictHostKeyChecking=no \
        "${SSH_USERS[$idx]}@${SERVERS[$idx]}" \
        "mysql -h\"$MYSQL_HOST\" -P\"$MYSQL_PORT\" -u\"$MYSQL_USER\" -p\"$MYSQL_PASS\" --table 2>/dev/null" \
        < "$sql_file"
    else
      mysql -h"$MYSQL_HOST" -P"$MYSQL_PORT" \
        -u"$MYSQL_USER" -p"$MYSQL_PASS" --table 2>/dev/null < "$sql_file"
    fi
  fi
  rm -f "$sql_file"
}

# =========================================
# Helper: mysql (single value) — dùng file tạm
# =========================================
mysql_q_on() {
  local idx=$1; local query=$2
  local sql_file
  sql_file=$(mktemp /tmp/moodle_sql_XXXXXX)
  echo "$query" > "$sql_file"

  if [ "$RUNTIME" = "docker" ]; then
    if [ "$ENV_MODE" = "server" ]; then
      ssh -T -p "${SSH_PORTS[$idx]}" -o StrictHostKeyChecking=no \
        "${SSH_USERS[$idx]}@${SERVERS[$idx]}" \
        "docker exec -i $CONTAINER mysql -u\"$MYSQL_USER\" -p\"$MYSQL_PASS\" -N 2>/dev/null" \
        < "$sql_file"
    else
      docker exec -i "$CONTAINER" \
        mysql -u"$MYSQL_USER" -p"$MYSQL_PASS" -N 2>/dev/null < "$sql_file"
    fi
  else
    if [ "$ENV_MODE" = "server" ]; then
      ssh -T -p "${SSH_PORTS[$idx]}" -o StrictHostKeyChecking=no \
        "${SSH_USERS[$idx]}@${SERVERS[$idx]}" \
        "mysql -h\"$MYSQL_HOST\" -P\"$MYSQL_PORT\" -u\"$MYSQL_USER\" -p\"$MYSQL_PASS\" -N 2>/dev/null" \
        < "$sql_file"
    else
      mysql -h"$MYSQL_HOST" -P"$MYSQL_PORT" \
        -u"$MYSQL_USER" -p"$MYSQL_PASS" -N 2>/dev/null < "$sql_file"
    fi
  fi
  rm -f "$sql_file"
}

# Alias dùng server đầu tiên (idx=0)
mysql_table() { mysql_table_on 0; }
mysql_q()     { mysql_q_on 0 "$1"; }

# =========================================
# BƯỚC 1: Chọn môi trường
# =========================================
setup_env() {
  while true; do
    echo ""
    echo -e "  ${BOLD}Môi trường thực thi${NC}"
    sep
    echo -e "  ${CYAN}1)${NC}  Local   — MariaDB đang chạy trên máy này"
    echo -e "  ${CYAN}2)${NC}  Server  — MariaDB đang chạy trên server remote"
    echo -e "  ${CYAN}q)${NC}  Thoát"
    echo ""
    read -rp "  Chọn [1/2/q]: " choice
    case "$choice" in
      1)
        ENV_MODE="local"
        SERVER_COUNT=1
        SERVERS=("localhost"); SSH_USERS=(""); SSH_PORTS=("")
        return 0
        ;;
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
        if ! check_ssh; then
          return 1
        fi
        return 0
        ;;
      q|Q) quit ;;
      *) warn "Nhập 1, 2 hoặc q." ;;
    esac
  done
}

# =========================================
# Check SSH song song
# =========================================
check_ssh() {
  echo ""
  echo -e "  Kiểm tra SSH ${SERVER_COUNT} server cùng lúc..."
  local tmp=$(mktemp -d); local pids=()

  for i in $(seq 0 $((SERVER_COUNT - 1))); do
    (
      ssh -p "${SSH_PORTS[$i]}" -o ConnectTimeout=5 -o BatchMode=yes \
        -o StrictHostKeyChecking=no "${SSH_USERS[$i]}@${SERVERS[$i]}" \
        "echo ok" &>/dev/null \
        && echo "ok" > "${tmp}/r_${i}" || echo "fail" > "${tmp}/r_${i}"
    ) &
    pids+=($!)
  done
  for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done

  echo ""
  local all_ok=true
  for i in $(seq 0 $((SERVER_COUNT - 1))); do
    local r=$(cat "${tmp}/r_${i}" 2>/dev/null || echo "fail")
    if [ "$r" = "ok" ]; then
      ok "${SSH_USERS[$i]}@${SERVERS[$i]}:${SSH_PORTS[$i]}"
    else
      fail "${SSH_USERS[$i]}@${SERVERS[$i]}:${SSH_PORTS[$i]} — không kết nối được"
      all_ok=false
    fi
  done
  rm -rf "$tmp"

  if [ "$all_ok" = false ]; then
    echo ""; warn "Một số server không SSH được."; return 1
  fi
  return 0
}

# =========================================
# BƯỚC 2: Chọn runtime + check
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
        if check_runtime; then return 0; fi
        ;;
      2)
        RUNTIME="service"
        echo ""
        read -rp "  MariaDB Host (127.0.0.1) : " input; MYSQL_HOST=${input:-127.0.0.1}
        read -rp "  MariaDB Port (3306)      : " input; MYSQL_PORT=${input:-3306}
        read -rp "  MySQL User   (root)      : " input; MYSQL_USER=${input:-root}
        read -rp "  MySQL Pass               : " MYSQL_PASS
        if check_runtime; then return 0; fi
        ;;
      b|B) return 1 ;;
      *) warn "Nhập 1, 2 hoặc b." ;;
    esac
  done
}

# =========================================
# Check runtime song song
# =========================================
check_runtime() {
  echo ""
  local check_count=$SERVER_COUNT
  [ "$ENV_MODE" = "local" ] && check_count=1
  local tmp=$(mktemp -d); local pids=()

  echo -e "  Kiểm tra runtime ${check_count} server cùng lúc..."

  for i in $(seq 0 $((check_count - 1))); do
    (
      if [ "$RUNTIME" = "docker" ]; then
        local running
        if [ "$ENV_MODE" = "server" ]; then
          running=$(ssh -p "${SSH_PORTS[$i]}" -o StrictHostKeyChecking=no \
            "${SSH_USERS[$i]}@${SERVERS[$i]}" \
            "docker inspect -f '{{.State.Running}}' $CONTAINER 2>/dev/null || echo NOT_FOUND")
        else
          running=$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || echo "NOT_FOUND")
        fi
        if [ "$running" = "NOT_FOUND" ]; then
          echo "fail:container '$CONTAINER' không tồn tại" > "${tmp}/r_${i}"; exit 0
        elif [ "$running" != "true" ]; then
          echo "fail:container '$CONTAINER' không đang chạy" > "${tmp}/r_${i}"; exit 0
        fi
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
    local r=$(cat "${tmp}/r_${i}" 2>/dev/null || echo "fail:không có kết quả")
    local label
    [ "$ENV_MODE" = "server" ] && label="${SERVERS[$i]}" || label="local"
    if [ "$r" = "ok" ]; then
      ok "$label"
    else
      fail "$label — ${r#fail:}"
      all_ok=false
    fi
  done
  rm -rf "$tmp"

  [ "$all_ok" = true ] && return 0 || return 1
}

# =========================================
# Chọn DB — lần lượt từng server
# SERVER_SELECTED_DBS[i] = "db1|db2|db3" (pipe-separated)
# =========================================
select_dbs() {
  local run_count=$SERVER_COUNT
  [ "$ENV_MODE" = "local" ] && run_count=1

  declare -g -a SERVER_SELECTED_DBS=()

  for i in $(seq 0 $((run_count - 1))); do
    local label
    [ "$ENV_MODE" = "server" ] && label="${SERVERS[$i]}" || label="local"

    # Load DB của server này
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
      SERVER_SELECTED_DBS+=("")
      continue
    fi

    while true; do
      echo ""
      echo -e "  ${BOLD}[Server: ${CYAN}${label}${NC}${BOLD}]${NC}  Chọn DB để check"
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
          # Tất cả DB của server này
          local joined
          joined=$(printf '%s|' "${DBS_ON_SERVER[@]}")
          SERVER_SELECTED_DBS+=("${joined%|}")
          break
          ;;
      esac

      IFS=',' read -ra choices <<< "${input// /}"
      local picked=() valid=1
      for choice in "${choices[@]}"; do
        if [[ "$choice" =~ ^[0-9]+$ ]] && \
           [ "$choice" -ge 1 ] && \
           [ "$choice" -le "${#DBS_ON_SERVER[@]}" ]; then
          picked+=("${DBS_ON_SERVER[$((choice-1))]}")
        else
          warn "'${choice}' không hợp lệ."; valid=0; break
        fi
      done

      [ "$valid" -eq 0 ] && continue

      # Deduplicate + sort
      mapfile -t picked < <(printf '%s\n' "${picked[@]}" | sort -u)
      if [ ${#picked[@]} -gt 0 ]; then
        local joined
        joined=$(printf '%s|' "${picked[@]}")
        SERVER_SELECTED_DBS+=("${joined%|}")
        break
      fi
    done
  done
}
# =========================================
# Check: FAST (idx + DB)
# =========================================
check_fast_on() {
  local idx=$1; local DB=$2
  mysql_table_on "$idx" << SQL
SELECT
  COUNT(*)                                                      AS 'Tables',
  SUM(table_rows)                                               AS 'Rows (est.)',
  ROUND(SUM(data_length)   / 1024 / 1024, 2)                   AS 'Data MB',
  ROUND(SUM(index_length)  / 1024 / 1024, 2)                   AS 'Index MB',
  ROUND(SUM(data_length + index_length) / 1024 / 1024, 2)      AS 'Total MB'
FROM information_schema.tables
WHERE table_schema = '${DB}';

SELECT
  RPAD(table_name, 22, ' ')                                     AS 'Table',
  LPAD(FORMAT(table_rows, 0), 12, ' ')                          AS 'Rows (est.)',
  LPAD(ROUND(data_length  / 1024 / 1024, 2), 10, ' ')          AS 'Data MB',
  LPAD(ROUND(index_length / 1024 / 1024, 2), 10, ' ')          AS 'Idx MB',
  LPAD(ROUND((data_length + index_length) / 1024 / 1024, 2), 10, ' ') AS 'Total MB'
FROM information_schema.tables
WHERE table_schema = '${DB}'
ORDER BY table_name;
SQL
}

# =========================================
# Check: EXACT (idx + DB)
# =========================================
check_exact_on() {
  local idx=$1; local DB=$2

  mapfile -t TABLES < <(
    mysql_q_on "$idx" "SELECT table_name FROM information_schema.tables
             WHERE table_schema='${DB}' ORDER BY table_name;"
  )

  if [ ${#TABLES[@]} -eq 0 ]; then
    warn "Không tìm thấy bảng nào trong ${DB}."; return
  fi

  local UNION=""
  for T in "${TABLES[@]}"; do
    [ -n "$UNION" ] && UNION+=" UNION ALL "
    UNION+="SELECT '${T}' AS tbl, COUNT(*) AS cnt FROM \`${DB}\`.\`${T}\`"
  done

  mysql_table_on "$idx" << SQL
SELECT
  ROUND(SUM(data_length + index_length) / 1024 / 1024, 2) AS 'Total Size MB',
  COUNT(*) AS 'Tables'
FROM information_schema.tables
WHERE table_schema = '${DB}';

SELECT
  RPAD(tbl, 22, ' ')            AS 'Table',
  LPAD(FORMAT(cnt, 0), 14, ' ') AS 'Exact Rows'
FROM ( ${UNION} ) x
ORDER BY tbl;

SELECT
  COUNT(*)  AS 'Tables',
  SUM(cnt)  AS 'Total Rows (exact)'
FROM ( ${UNION} ) x;
SQL
}

# =========================================
# Check: VERIFY (idx + DB)
# =========================================
check_verify_on() {
  local idx=$1; local DB=$2

  dim "  fast (estimated)"
  check_fast_on "$idx" "$DB"

  echo ""
  dim "  exact (COUNT*)"
  check_exact_on "$idx" "$DB"

  echo ""
  echo -e "  ${BOLD}Drift analysis${NC}"
  sep

  mapfile -t TABLES < <(
    mysql_q_on "$idx" "SELECT table_name FROM information_schema.tables
             WHERE table_schema='${DB}' ORDER BY table_name;"
  )

  printf "  %-22s %12s %12s %8s\n" "Table" "Est Rows" "Exact Rows" "Drift"
  sep

  for T in "${TABLES[@]}"; do
    local EST EXACT DRIFT
    EST=$(mysql_q_on "$idx" "SELECT table_rows FROM information_schema.tables
                   WHERE table_schema='${DB}' AND table_name='${T}';" | tr -d '[:space:]')
    EXACT=$(mysql_q_on "$idx" "SELECT COUNT(*) FROM \`${DB}\`.\`${T}\`;" | tr -d '[:space:]')

    if [[ "$EXACT" =~ ^[0-9]+$ ]] && [ "$EXACT" -gt 0 ]; then
      DRIFT=$(awk -v e="${EST:-0}" -v a="$EXACT" \
        'BEGIN { printf "%+.1f%%", (e-a)*100/a }')
    else
      DRIFT="N/A"
    fi

    printf "  %-22s %12s %12s %8s\n" "$T" "${EST:-0}" "${EXACT:-0}" "$DRIFT"
  done
  echo ""
}

# =========================================
# Helper: capture check output của 1 server/DB vào file
# =========================================
capture_check() {
  local idx=$1; local DB=$2
  case "$MODE" in
    fast)   check_fast_on   "$idx" "$DB" ;;
    exact)  check_exact_on  "$idx" "$DB" ;;
    verify) check_verify_on "$idx" "$DB" ;;
  esac
}

# =========================================
# Helper: zip 2 file text thành 2 cột song song
# Tự động tính col_width theo terminal, căn chỉnh đúng kể cả ANSI
# =========================================
strip_ansi() {
  sed 's/\x1b\[[0-9;]*[mK]//g'
}

print_two_columns() {
  local file1=$1 file2=$2
  local label1=$3 label2=$4

  # Lấy terminal width, fallback 200
  local term_width
  term_width=$(tput cols 2>/dev/null || echo 200)

  # Tính max plain-text width của mỗi cột
  local max1=0 max2=0
  while IFS= read -r line; do
    local plain; plain=$(echo "$line" | strip_ansi)
    [ ${#plain} -gt $max1 ] && max1=${#plain}
  done < "$file1"
  while IFS= read -r line; do
    local plain; plain=$(echo "$line" | strip_ansi)
    [ ${#plain} -gt $max2 ] && max2=${#plain}
  done < "$file2"

  # Gap giữa 2 cột
  local gap=4
  # col_width = max của (max1, (term_width - gap) / 2)
  local col_width=$(( (term_width - gap) / 2 ))
  [ $max1 -gt $col_width ] && col_width=$max1

  # Header 2 cột
  local h1="══ ${label1} ══"
  local h2="══ ${label2} ══"
  local plain_h1; plain_h1=$(echo "$h1" | strip_ansi)
  local pad_h=$(( col_width - ${#plain_h1} ))
  [ $pad_h -lt 0 ] && pad_h=0
  printf "  ${BOLD}${CYAN}%s${NC}%${pad_h}s  ${BOLD}${CYAN}%s${NC}\n" "$h1" "" "$h2"

  # Zip từng dòng
  local lines1=() lines2=()
  mapfile -t lines1 < "$file1"
  mapfile -t lines2 < "$file2"

  local max_lines=${#lines1[@]}
  [ ${#lines2[@]} -gt $max_lines ] && max_lines=${#lines2[@]}

  for ((k=0; k<max_lines; k++)); do
    local l1="${lines1[$k]:-}"
    local l2="${lines2[$k]:-}"
    local plain1; plain1=$(echo "$l1" | strip_ansi)
    local pad=$(( col_width - ${#plain1} ))
    [ $pad -lt 0 ] && pad=0
    printf "%s%${pad}s  %s\n" "$l1" "" "$l2"
  done
}
# =========================================
# Run check: 1→dọc | 2→2 cột (chỉ DB chung) | 3+→dọc
# =========================================
run_check() {
  local run_count=$SERVER_COUNT
  [ "$ENV_MODE" = "local" ] && run_count=1

  echo ""
  echo -e "  ${BOLD}Snapshot: $(date '+%Y-%m-%d %H:%M:%S')${NC}  ${DIM}mode: ${MODE}${NC}"

  # ── 2 server: phân loại DB ──
  if [ "$run_count" -eq 2 ]; then
    local label0 label1
    [ "$ENV_MODE" = "server" ] && label0="${SERVERS[0]}" || label0="local"
    [ "$ENV_MODE" = "server" ] && label1="${SERVERS[1]}" || label1="local"

    IFS='|' read -ra DBS0 <<< "${SERVER_SELECTED_DBS[0]:-}"
    IFS='|' read -ra DBS1 <<< "${SERVER_SELECTED_DBS[1]:-}"

    # Phân loại: only0, only1, both
    local -a only0=() only1=() both=()
    for db in "${DBS0[@]}"; do
      if printf '%s\n' "${DBS1[@]}" | grep -qx "$db"; then
        both+=("$db")
      else
        only0+=("$db")
      fi
    done
    for db in "${DBS1[@]}"; do
      if ! printf '%s\n' "${DBS0[@]}" | grep -qx "$db"; then
        only1+=("$db")
      fi
    done

    # DB chỉ có ở server 0 → dọc với label server 0
    if [ ${#only0[@]} -gt 0 ]; then
      echo ""
      echo -e "  ${BOLD}${CYAN}══ Server: ${label0} ══${NC}"
      for DB in "${only0[@]}"; do
        echo ""
        sep
        echo -e "  ${BOLD}DB:${NC} $DB"
        sep
        capture_check 0 "$DB"
      done
    fi

    # DB chỉ có ở server 1 → dọc với label server 1
    if [ ${#only1[@]} -gt 0 ]; then
      echo ""
      echo -e "  ${BOLD}${CYAN}══ Server: ${label1} ══${NC}"
      for DB in "${only1[@]}"; do
        echo ""
        sep
        echo -e "  ${BOLD}DB:${NC} $DB"
        sep
        capture_check 1 "$DB"
      done
    fi

    # DB có ở cả 2 → 2 cột song song
    for DB in "${both[@]}"; do
      echo ""
      sep
      echo -e "  ${BOLD}DB:${NC} $DB"
      sep

      local tmp0 tmp1
      tmp0=$(mktemp); tmp1=$(mktemp)

      ( capture_check 0 "$DB" > "$tmp0" 2>/dev/null ) &
      local pid0=$!
      ( capture_check 1 "$DB" > "$tmp1" 2>/dev/null ) &
      local pid1=$!
      wait "$pid0" "$pid1"

      print_two_columns "$tmp0" "$tmp1" "$label0" "$label1"
      rm -f "$tmp0" "$tmp1"
    done

  # ── 1 server hoặc 3+ server: dọc ──
  else
    for i in $(seq 0 $((run_count - 1))); do
      local label
      [ "$ENV_MODE" = "server" ] && label="${SERVERS[$i]}" || label="local"

      echo ""
      echo -e "  ${BOLD}${CYAN}══ Server: ${label} ══${NC}"

      local db_str="${SERVER_SELECTED_DBS[$i]:-}"
      if [ -z "$db_str" ]; then
        warn "Không có DB nào được chọn cho ${label}."; continue
      fi

      IFS='|' read -ra DBS_TO_CHECK <<< "$db_str"
      for DB in "${DBS_TO_CHECK[@]}"; do
        echo ""
        sep
        echo -e "  ${BOLD}DB:${NC} $DB"
        sep
        capture_check "$i" "$DB"
      done
    done
  fi

  echo ""
  sep
  dim "  Done: $(date '+%Y-%m-%d %H:%M:%S')"
  echo ""
}
# =========================================
# MAIN
# =========================================
echo ""
echo -e "  ${BOLD}Moodle DB Checker${NC}"
echo ""

# Bước 1: Môi trường
while true; do
  setup_env && break
done

# Bước 2: Runtime (b → quay lại chọn env)
while true; do
  setup_runtime && break
  while true; do
    setup_env && break
  done
done

# Tóm tắt
echo ""
sep
if [ "$ENV_MODE" = "local" ]; then
  info "Môi trường : Local"
else
  for i in $(seq 0 $((SERVER_COUNT - 1))); do
    info "Server #$((i+1))  : ${SSH_USERS[$i]}@${SERVERS[$i]}:${SSH_PORTS[$i]}"
  done
fi
[ "$RUNTIME" = "docker" ] \
  && info "Runtime    : Docker  (container: $CONTAINER)" \
  || info "Runtime    : Service (${MYSQL_HOST}:${MYSQL_PORT})"
info "Mode       : ${MODE}"
sep

while true; do
  select_dbs
  run_check

  read -rp "  Check tiếp? [y/q]: " again
  case "$again" in
    y|Y) continue ;;
    *)   quit ;;
  esac
done
