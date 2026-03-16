#!/bin/bash

# ============================================================
#  AUTO ACTIVITY GENERATOR — Moodle
#  Chạy: bash generate_moodle_auto_db.sh
# ============================================================

INTERVAL=5
USERS_PER_TICK=5

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
# Helper: mysql exec (stdin) — file tạm
# =========================================
mysql_exec_on() {
  local idx=$1
  local sql_file
  sql_file=$(mktemp /tmp/moodle_sql_XXXXXX)
  cat > "$sql_file"

  if [ "$RUNTIME" = "docker" ]; then
    if [ "$ENV_MODE" = "server" ]; then
      ssh -T -p "${SSH_PORTS[$idx]}" -o StrictHostKeyChecking=no \
        "${SSH_USERS[$idx]}@${SERVERS[$idx]}" \
        "docker exec -i $CONTAINER mysql -u\"$MYSQL_USER\" -p\"$MYSQL_PASS\" 2>/dev/null" \
        < "$sql_file"
    else
      docker exec -i "$CONTAINER" \
        mysql -u"$MYSQL_USER" -p"$MYSQL_PASS" 2>/dev/null < "$sql_file"
    fi
  else
    if [ "$ENV_MODE" = "server" ]; then
      ssh -T -p "${SSH_PORTS[$idx]}" -o StrictHostKeyChecking=no \
        "${SSH_USERS[$idx]}@${SERVERS[$idx]}" \
        "mysql -h\"$MYSQL_HOST\" -P\"$MYSQL_PORT\" -u\"$MYSQL_USER\" -p\"$MYSQL_PASS\" 2>/dev/null" \
        < "$sql_file"
    else
      mysql -h"$MYSQL_HOST" -P"$MYSQL_PORT" \
        -u"$MYSQL_USER" -p"$MYSQL_PASS" 2>/dev/null < "$sql_file"
    fi
  fi
  rm -f "$sql_file"
}

# =========================================
# Helper: mysql query (single value) — file tạm
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

get_max_on() {
  local idx=$1 DB=$2 TBL=$3
  mysql_q_on "$idx" "SELECT COALESCE(MAX(id),0) FROM \`$DB\`.\`$TBL\`;" | tr -d '[:space:]'
}

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
    [ "$r" = "ok" ] \
      && ok "${SSH_USERS[$i]}@${SERVERS[$i]}:${SSH_PORTS[$i]}" \
      || { fail "${SSH_USERS[$i]}@${SERVERS[$i]}:${SSH_PORTS[$i]} — không kết nối được"; all_ok=false; }
  done
  rm -rf "$tmp"
  [ "$all_ok" = true ] && return 0 || { echo ""; warn "Một số server không SSH được."; return 1; }
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
        if check_runtime; then return 0; fi ;;
      2)
        RUNTIME="service"
        echo ""
        read -rp "  MariaDB Host (127.0.0.1) : " input; MYSQL_HOST=${input:-127.0.0.1}
        read -rp "  MariaDB Port (3306)      : " input; MYSQL_PORT=${input:-3306}
        read -rp "  MySQL User   (root)      : " input; MYSQL_USER=${input:-root}
        read -rp "  MySQL Pass               : " MYSQL_PASS
        if check_runtime; then return 0; fi ;;
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
    local r=$(cat "${tmp}/r_${i}" 2>/dev/null || echo "fail:không có kết quả")
    local label; [ "$ENV_MODE" = "server" ] && label="${SERVERS[$i]}" || label="local"
    [ "$r" = "ok" ] && ok "$label" || { fail "$label — ${r#fail:}"; all_ok=false; }
  done
  rm -rf "$tmp"
  [ "$all_ok" = true ] && return 0 || return 1
}

# =========================================
# Load DB của 1 server
# =========================================
load_databases_on() {
  local idx=$1
  mysql_q_on "$idx" "SELECT schema_name
           FROM information_schema.schemata
           WHERE schema_name NOT IN (
             'information_schema','performance_schema',
             'mysql','sys','innodb'
           )
           ORDER BY schema_name;"
}

# =========================================
# Chọn DB — lần lượt từng server
# SERVER_SELECTED_DBS[i] = "db1|db2|..." (pipe-separated)
# =========================================
select_dbs() {
  local run_count=$SERVER_COUNT
  [ "$ENV_MODE" = "local" ] && run_count=1
  declare -g -a SERVER_SELECTED_DBS=()

  for i in $(seq 0 $((run_count - 1))); do
    local label
    [ "$ENV_MODE" = "server" ] && label="${SERVERS[$i]}" || label="local"

    mapfile -t DBS_ON_SERVER < <(load_databases_on "$i" 2>/dev/null)

    if [ ${#DBS_ON_SERVER[@]} -eq 0 ]; then
      warn "Server ${label} không có DB nào — bỏ qua."
      SERVER_SELECTED_DBS+=(""); continue
    fi

    while true; do
      echo ""
      echo -e "  ${BOLD}[Server: ${CYAN}${label}${NC}${BOLD}]${NC}  Chọn DB để chạy auto"
      sep
      for j in "${!DBS_ON_SERVER[@]}"; do
        local db="${DBS_ON_SERVER[$j]}"
        local mu mc
        mu=$(get_max_on "$i" "$db" "mdl_user" 2>/dev/null || echo "?")
        mc=$(get_max_on "$i" "$db" "mdl_course" 2>/dev/null || echo "?")
        if [[ "$mu" =~ ^[0-9]+$ ]] && [ "$mu" -gt 0 ]; then
          printf "  ${CYAN}%2d)${NC}  %-38s  ${YELLOW}users≈%s  courses≈%s${NC}\n" \
            "$((j+1))" "$db" "$mu" "$mc"
        else
          printf "  ${CYAN}%2d)${NC}  %-38s  ${DIM}chưa có data${NC}\n" "$((j+1))" "$db"
        fi
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
          SERVER_SELECTED_DBS+=("${joined%|}")
          break ;;
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
        SERVER_SELECTED_DBS+=("${joined%|}")
        break
      fi
    done
  done
}

# =========================================
# Kiểm tra DB có data Moodle không
# =========================================
check_selected() {
  local run_count=$SERVER_COUNT
  [ "$ENV_MODE" = "local" ] && run_count=1
  local all_ok=1
  echo ""
  for i in $(seq 0 $((run_count - 1))); do
    local label; [ "$ENV_MODE" = "server" ] && label="${SERVERS[$i]}" || label="local"
    local db_str="${SERVER_SELECTED_DBS[$i]:-}"
    [ -z "$db_str" ] && continue
    IFS='|' read -ra DBS <<< "$db_str"
    for DB in "${DBS[@]}"; do
      local mu mc
      mu=$(get_max_on "$i" "$DB" "mdl_user")
      mc=$(get_max_on "$i" "$DB" "mdl_course")
      if [[ "${mu:-0}" -le 0 ]] || [[ "${mc:-0}" -le 0 ]]; then
        warn "[${label}] DB ${DB:0:12}…  chưa có data — chạy generate_moodle_db.sh trước."
        all_ok=0
      else
        ok "[${label}] DB ${DB:0:12}…  users=${mu}  courses=${mc}"
      fi
    done
  done
  [ "$all_ok" -eq 0 ] && exit 1
}

# =========================================
# 1 tick — insert activity cho 1 server/DB
# =========================================
do_tick_on() {
  local idx=$1; local DB=$2
  local MU MC
  MU=$(get_max_on "$idx" "$DB" "mdl_user")
  MC=$(get_max_on "$idx" "$DB" "mdl_course")

  [ "${MU:-0}" -le 0 ] && { warn "Không có user trong ${DB:0:12}…"; return 1; }
  [ "${MC:-0}" -le 0 ] && { warn "Không có course trong ${DB:0:12}…"; return 1; }

  mysql_exec_on "$idx" << SQL
USE \`${DB}\`;

INSERT INTO mdl_logstore (userid, courseid, action, target, ip, data, created_at)
SELECT
  FLOOR(RAND()*${MU})+1,
  FLOOR(RAND()*${MC})+1,
  'viewed',
  ELT(1+FLOOR(RAND()*5),'course','module','page','resource','block'),
  CONCAT(FLOOR(RAND()*223)+1,'.',FLOOR(RAND()*255),'.',FLOOR(RAND()*255),'.',FLOOR(RAND()*254)+1),
  CONCAT('{"dur":',FLOOR(RAND()*600)+10,'}'),
  NOW()
FROM (SELECT 1 n UNION ALL SELECT 2 UNION ALL SELECT 3
      UNION ALL SELECT 4 UNION ALL SELECT 5) g
LIMIT ${USERS_PER_TICK};

INSERT INTO mdl_logstore (userid, courseid, action, target, ip, data, created_at)
SELECT
  FLOOR(RAND()*${MU})+1,
  0,
  ELT(1+FLOOR(RAND()*2),'loggedin','loggedout'),
  'user',
  CONCAT(FLOOR(RAND()*223)+1,'.',FLOOR(RAND()*255),'.',FLOOR(RAND()*255),'.',FLOOR(RAND()*254)+1),
  '{}',
  NOW()
FROM (SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3) g;

INSERT INTO mdl_forum_posts (userid, courseid, subject, message, created_at)
SELECT
  FLOOR(RAND()*${MU})+1,
  FLOOR(RAND()*${MC})+1,
  CONCAT(ELT(1+FLOOR(RAND()*4),'Hỏi về','Thảo luận:','Re:','Nhờ tư vấn:'),
         ' ', ELT(1+FLOOR(RAND()*4),'bài tập','deadline','tài liệu','điểm số')),
  ELT(1+FLOOR(RAND()*4),
    'Thầy/cô giải thích thêm phần này được không ạ?',
    'Bài tập nộp muộn có bị trừ điểm không?',
    'Cảm ơn thầy, mình hiểu bài hơn rồi ạ!',
    'Nhờ các bạn review bài giúp mình với.'),
  NOW()
FROM (SELECT 1 UNION ALL SELECT 2) g;

INSERT INTO mdl_assign (userid, courseid, title, submission, grade, status, submitted_at)
SELECT
  FLOOR(RAND()*${MU})+1,
  FLOOR(RAND()*${MC})+1,
  CONCAT('Bài nộp – ', DATE_FORMAT(NOW(),'%Y-%m-%d %H:%i')),
  CONCAT(ELT(1+FLOOR(RAND()*3),'Phân tích: ','Kết quả: ','Đề xuất: '),
         'Lorem ipsum dolor sit amet, consectetur adipiscing elit.'),
  ROUND(RAND()*100,2),
  ELT(1+FLOOR(RAND()*3),'submitted','graded','draft'),
  NOW()
FROM (SELECT 1 UNION ALL SELECT 2) g;

INSERT INTO mdl_quiz (userid, courseid, quiz_name, score, max_score, attempt, time_taken, started_at)
SELECT
  FLOOR(RAND()*${MU})+1,
  FLOOR(RAND()*${MC})+1,
  CONCAT(ELT(1+FLOOR(RAND()*4),'Kiểm tra nhanh','Ôn tập','Quiz thực hành','Bài thi thử'),
         ' – ', DATE_FORMAT(NOW(),'%H:%i')),
  ROUND(RAND()*10,2), 10.00,
  FLOOR(RAND()*3)+1,
  FLOOR(RAND()*1800)+60,
  NOW()
FROM (SELECT 1 UNION ALL SELECT 2) g;

INSERT INTO mdl_message (from_userid, to_userid, subject, body, is_read, sent_at)
SELECT
  FLOOR(RAND()*${MU})+1,
  FLOOR(RAND()*${MU})+1,
  CONCAT(ELT(1+FLOOR(RAND()*4),'Hỏi bài','Nhờ giúp','Thông báo','Nhắc nhở'),
         ' – ', DATE_FORMAT(NOW(),'%H:%i')),
  ELT(1+FLOOR(RAND()*4),
    'Bạn ơi cho mình hỏi bài tập tuần này làm thế nào?',
    'Mình cần giúp phần bài tập lớn, bạn rảnh không?',
    'Nhắc nộp bài trước deadline ngày mai nhé!',
    'Nhóm họp lúc 8h tối nay, bạn online không?'),
  FLOOR(RAND()*2),
  NOW()
FROM (SELECT 1 UNION ALL SELECT 2) g;

SET @gmax := (SELECT MAX(id) FROM mdl_grade_grades);
UPDATE mdl_grade_grades
SET finalgrade = ROUND(RAND()*100,2),
    feedback   = CONCAT('Auto-graded ',DATE_FORMAT(NOW(),'%Y-%m-%d %H:%i:%s')),
    created_at = NOW()
WHERE id BETWEEN FLOOR(RAND()*@gmax)+1 AND FLOOR(RAND()*@gmax)+4;

SET @emax := (SELECT MAX(id) FROM mdl_enrol);
UPDATE mdl_enrol
SET status      = FLOOR(RAND()*2),
    enrolled_at = NOW()
WHERE id BETWEEN FLOOR(RAND()*@emax)+1 AND FLOOR(RAND()*@emax)+3;
SQL
}

# =========================================
# Quick count activity rows
# =========================================
quick_count_on() {
  local idx=$1; local DB=$2
  mysql_q_on "$idx" "SELECT COALESCE(SUM(table_rows),0)
           FROM information_schema.tables
           WHERE table_schema='${DB}'
             AND table_name IN (
               'mdl_logstore','mdl_forum_posts',
               'mdl_assign','mdl_quiz','mdl_message'
             );" | tr -d '[:space:]'
}

# =========================================
# Trap Ctrl+C — summary
# =========================================
TICK=0
START_TS=$(date +%s)

cleanup() {
  echo ""
  local ELAPSED=$(( $(date +%s) - START_TS ))
  local run_count=$SERVER_COUNT
  [ "$ENV_MODE" = "local" ] && run_count=1

  echo ""
  echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}  Dừng — Summary${NC}"
  printf   "  Thời gian : %02d:%02d:%02d\n" \
    $((ELAPSED/3600)) $((ELAPSED%3600/60)) $((ELAPSED%60))
  echo     "  Tổng tick : ${TICK}"
  echo ""
  for i in $(seq 0 $((run_count - 1))); do
    local label; [ "$ENV_MODE" = "server" ] && label="${SERVERS[$i]}" || label="local"
    local db_str="${SERVER_SELECTED_DBS[$i]:-}"
    [ -z "$db_str" ] && continue
    IFS='|' read -ra DBS <<< "$db_str"
    for DB in "${DBS[@]}"; do
      local total; total=$(quick_count_on "$i" "$DB")
      echo "  [${label}] DB ${DB:0:12}…  activity rows ≈ ${total:-?}"
    done
  done
  echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
  echo ""
  exit 0
}
trap cleanup INT TERM

# =========================================
# MAIN
# =========================================
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}  AUTO ACTIVITY GENERATOR — Moodle${NC}"
echo    "  Interval  : ${INTERVAL}s / tick  |  User/tick : ${USERS_PER_TICK}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
echo ""

# Bước 1: Môi trường
while true; do
  setup_env && break
done

# Bước 2: Runtime (b → quay lại env)
while true; do
  setup_runtime && break
  while true; do setup_env && break; done
done

# Tóm tắt kết nối
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
info "Interval   : ${INTERVAL}s / tick  |  User/tick: ${USERS_PER_TICK}"
sep

# Bước 3: Chọn DB từng server
select_dbs

# Bước 4: Validate data
check_selected

echo ""
echo -e "  Bắt đầu. Nhấn ${BOLD}Ctrl+C${NC} để dừng."
echo ""

# =========================================
# Main loop — tick song song trên tất cả server×DB
# =========================================
run_count=$SERVER_COUNT
[ "$ENV_MODE" = "local" ] && run_count=1

while true; do
  TICK=$((TICK+1))
  echo -e "  ── ${CYAN}Tick #${TICK}${NC}  $(date '+%H:%M:%S')  ─────────────────────────────"

  tick_pids=()
  for i in $(seq 0 $((run_count - 1))); do
    srv_label="${SERVERS[$i]:-local}"
    [ "$ENV_MODE" = "local" ] && srv_label="local"
    db_str="${SERVER_SELECTED_DBS[$i]:-}"
    [ -z "$db_str" ] && continue
    IFS='|' read -ra DBS <<< "$db_str"
    for DB in "${DBS[@]}"; do
      (
        if do_tick_on "$i" "$DB"; then
          total=$(quick_count_on "$i" "$DB")
          ok "[${srv_label}] DB ${DB:0:12}…  activity ≈ ${total:-?} rows"
        else
          fail "[${srv_label}] DB ${DB:0:12}…  lỗi tick"
        fi
      ) &
      tick_pids+=($!)
    done
  done
  for pid in "${tick_pids[@]}"; do wait "$pid" 2>/dev/null || true; done

  echo ""
  sleep "$INTERVAL"
done
