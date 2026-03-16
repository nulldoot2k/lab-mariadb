#!/bin/bash

# ============================================================
#  MOODLE DATA GENERATOR
#  Chạy: bash generate_moodle_db.sh
# ============================================================

BATCH_USERS=10000
BATCH_COURSES=1000
BATCH_ENROL=50000
BATCH_FORUM=30000
BATCH_GRADES=50000
BATCH_LOGS=100000
BATCH_ASSIGN=20000
BATCH_QUIZ=20000
BATCH_MESSAGE=30000

# =========================================
# Colors
# =========================================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

ok()   { echo -e "  ${GREEN}✔${NC} $1"; }
fail() { echo -e "  ${RED}✘${NC} $1"; }
warn() { echo -e "  ${YELLOW}⚠${NC}  $1"; }
info() { echo -e "  ${CYAN}→${NC} $1"; }
log()  { echo "  [$(date '+%H:%M:%S')] $1"; }
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
ENV_MODE=""         # local | server
RUNTIME=""          # docker | service
SERVER_COUNT=0
declare -a SERVERS=() SSH_USERS=() SSH_PORTS=()
CONTAINER=""
MYSQL_HOST="127.0.0.1"
MYSQL_PORT=3306
MYSQL_USER="root"
MYSQL_PASS="rootpassword"

# =========================================
# Helper: chạy lệnh mysql trên 1 server (theo index)
# =========================================
mysql_exec_on() {
  local idx=$1
  # Ghi SQL vào file tạm — tránh vấn đề subshell & SSH stdin khi chạy song song
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

mysql_q_on() {
  local idx=$1; local query=$2
  # Dùng file tạm để tránh bash remote interpret backtick/special chars trong query
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

# Alias cho local hoặc server đơn (idx=0)
mysql_exec() { mysql_exec_on 0; }
mysql_q()    { mysql_q_on 0 "$1"; }

gen_uuid() {
  cat /proc/sys/kernel/random/uuid 2>/dev/null \
    || python3 -c "import uuid; print(uuid.uuid4())" 2>/dev/null
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
        # Check SSH song song
        if ! check_ssh; then
          return 1   # quay lại vòng lặp → hỏi lại từ đầu
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
    echo ""
    warn "Một số server không SSH được."
    return 1
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
# Check runtime (container + MariaDB) song song
# =========================================
check_runtime() {
  echo ""
  local tmp=$(mktemp -d); local pids=()
  local check_count=$SERVER_COUNT
  [ "$ENV_MODE" = "local" ] && check_count=1

  echo -e "  Kiểm tra runtime ${check_count} server cùng lúc..."

  for i in $(seq 0 $((check_count - 1))); do
    (
      local result=""
      # Check container tồn tại (nếu docker)
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

      # Check MariaDB
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
# Load DB + helpers (dùng server idx=0 làm reference)
# =========================================
load_databases() {
  mapfile -t EXISTING_DBS < <(
    mysql_q "SELECT schema_name
             FROM information_schema.schemata
             WHERE schema_name NOT IN (
               'information_schema','performance_schema',
               'mysql','sys','innodb'
             )
             ORDER BY schema_name;"
  )
}

db_info() {
  local DB=$1
  local mu mc
  mu=$(mysql_q "SELECT COALESCE(MAX(id),0) FROM \`${DB}\`.mdl_user;" 2>/dev/null | tr -d '[:space:]')
  if [[ "$mu" =~ ^[0-9]+$ ]] && [ "$mu" -gt 0 ]; then
    mc=$(mysql_q "SELECT COALESCE(MAX(id),0) FROM \`${DB}\`.mdl_course;" 2>/dev/null | tr -d '[:space:]')
    echo "users≈${mu}  courses≈${mc}"
  else
    echo "trống"
  fi
}

# =========================================
# Menu gen data
# =========================================
ask_mode() {
  while true; do
    echo ""
    echo -e "  ${BOLD}Menu chính${NC}"
    sep
    echo -e "  ${CYAN}1)${NC}  Gen thêm data vào DB có sẵn"
    echo -e "  ${CYAN}2)${NC}  Tạo DB mới và gen data"
    echo -e "  ${CYAN}q)${NC}  Thoát"
    echo ""
    read -rp "  Chọn [1/2/q]: " mode
    case "$mode" in
      1) MODE="existing"; return ;;
      2) MODE="new";      return ;;
      q|Q) quit ;;
      *) warn "Nhập 1, 2 hoặc q." ;;
    esac
  done
}

select_existing() {
  load_databases

  if [ ${#EXISTING_DBS[@]} -eq 0 ]; then
    echo ""
    warn "Chưa có DB nào."
    echo ""
    read -rp "  Chuyển sang tạo DB mới? [y/b/q]: " ans
    case "$ans" in
      y|Y) MODE="new"; return 0 ;;
      b|B) return 1 ;;
      *)   quit ;;
    esac
  fi

  while true; do
    echo ""
    echo -e "  ${BOLD}DB hiện có${NC}"
    sep
    for i in "${!EXISTING_DBS[@]}"; do
      local dinfo
      dinfo=$(db_info "${EXISTING_DBS[$i]}")
      printf "  ${CYAN}%2d)${NC}  %-40s  ${YELLOW}%s${NC}\n" \
        "$((i+1))" "${EXISTING_DBS[$i]}" "$dinfo"
    done
    echo ""
    dim "  Chọn 1 hoặc nhiều DB, cách nhau bởi dấu phẩy. Vd: 1,2"
    dim "  b) Quay lại   q) Thoát"
    echo ""
    read -rp "  Nhập [1-${#EXISTING_DBS[@]}/b/q]: " input

    case "${input// /}" in
      b|B) return 1 ;;
      q|Q) quit ;;
    esac

    IFS=',' read -ra choices <<< "${input// /}"
    TARGET_DBS=()
    local valid=1
    for choice in "${choices[@]}"; do
      if [[ "$choice" =~ ^[0-9]+$ ]] && \
         [ "$choice" -ge 1 ] && [ "$choice" -le "${#EXISTING_DBS[@]}" ]; then
        TARGET_DBS+=("${EXISTING_DBS[$((choice-1))]}")
      else
        warn "'${choice}' không hợp lệ."; valid=0; break
      fi
    done
    [ "$valid" -eq 0 ] && continue
    mapfile -t TARGET_DBS < <(printf '%s\n' "${TARGET_DBS[@]}" | sort -u)
    [ "${#TARGET_DBS[@]}" -gt 0 ] && return 0
  done
}

select_new() {
  while true; do
    echo ""
    echo -e "  ${BOLD}Tạo DB mới${NC}"
    sep
    dim "  Tên DB sẽ được tạo tự động dạng UUID"
    dim "  b) Quay lại   q) Thoát"
    echo ""
    read -rp "  Số lượng DB cần tạo [1-20/b/q]: " input

    case "${input// /}" in
      b|B) return 1 ;;
      q|Q) quit ;;
    esac

    if [[ "$input" =~ ^[0-9]+$ ]] && [ "$input" -ge 1 ] && [ "$input" -le 20 ]; then
      TARGET_DBS=()
      echo ""
      for (( i=0; i<input; i++ )); do
        local uuid; uuid=$(gen_uuid)
        TARGET_DBS+=("$uuid")
        info "$uuid"
      done
      return 0
    else
      warn "Nhập số từ 1 đến 20."
    fi
  done
}

# =========================================
# generate_seq
# =========================================
generate_seq() {
  local N=$1
  echo "SELECT a.N + b.N*10 + c.N*100 + d.N*1000 + e.N*10000 + 1 AS seq
    FROM
      (SELECT 0 AS N UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) a
      CROSS JOIN (SELECT 0 AS N UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) b
      CROSS JOIN (SELECT 0 AS N UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) c
      CROSS JOIN (SELECT 0 AS N UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) d
      CROSS JOIN (SELECT 0 AS N UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) e
    WHERE a.N + b.N*10 + c.N*100 + d.N*1000 + e.N*10000 + 1 <= $N"
}

# =========================================
# Setup tables + Insert data (cho 1 server theo idx)
# =========================================
setup_tables_on() {
  local idx=$1; local DB=$2
  mysql_exec_on "$idx" << SQL
CREATE DATABASE IF NOT EXISTS \`$DB\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE \`$DB\`;
CREATE TABLE IF NOT EXISTS mdl_user (
  id BIGINT AUTO_INCREMENT PRIMARY KEY,
  username VARCHAR(100), email VARCHAR(200),
  firstname VARCHAR(100), lastname VARCHAR(100),
  password VARCHAR(255), bio TEXT,
  city VARCHAR(100), country VARCHAR(2),
  created_at DATETIME DEFAULT NOW()
);
CREATE TABLE IF NOT EXISTS mdl_course (
  id BIGINT AUTO_INCREMENT PRIMARY KEY,
  fullname VARCHAR(255), shortname VARCHAR(100),
  summary TEXT, category INT,
  startdate DATETIME, enddate DATETIME,
  created_at DATETIME DEFAULT NOW()
);
CREATE TABLE IF NOT EXISTS mdl_enrol (
  id BIGINT AUTO_INCREMENT PRIMARY KEY,
  userid BIGINT, courseid BIGINT,
  status TINYINT DEFAULT 0,
  enrolled_at DATETIME DEFAULT NOW()
);
CREATE TABLE IF NOT EXISTS mdl_forum_posts (
  id BIGINT AUTO_INCREMENT PRIMARY KEY,
  userid BIGINT, courseid BIGINT,
  subject VARCHAR(255), message LONGTEXT,
  created_at DATETIME DEFAULT NOW()
);
CREATE TABLE IF NOT EXISTS mdl_grade_grades (
  id BIGINT AUTO_INCREMENT PRIMARY KEY,
  userid BIGINT, courseid BIGINT, itemid BIGINT,
  finalgrade DECIMAL(10,5), feedback TEXT,
  created_at DATETIME DEFAULT NOW()
);
CREATE TABLE IF NOT EXISTS mdl_logstore (
  id BIGINT AUTO_INCREMENT PRIMARY KEY,
  userid BIGINT, courseid BIGINT,
  action VARCHAR(100), target VARCHAR(100),
  ip VARCHAR(45), data TEXT,
  created_at DATETIME DEFAULT NOW()
);
CREATE TABLE IF NOT EXISTS mdl_assign (
  id BIGINT AUTO_INCREMENT PRIMARY KEY,
  userid BIGINT, courseid BIGINT,
  title VARCHAR(255), submission LONGTEXT,
  grade DECIMAL(10,2), status VARCHAR(20) DEFAULT 'submitted',
  submitted_at DATETIME DEFAULT NOW()
);
CREATE TABLE IF NOT EXISTS mdl_quiz (
  id BIGINT AUTO_INCREMENT PRIMARY KEY,
  userid BIGINT, courseid BIGINT,
  quiz_name VARCHAR(255),
  score DECIMAL(5,2), max_score DECIMAL(5,2),
  attempt TINYINT DEFAULT 1, time_taken INT COMMENT 'seconds',
  started_at DATETIME DEFAULT NOW()
);
CREATE TABLE IF NOT EXISTS mdl_message (
  id BIGINT AUTO_INCREMENT PRIMARY KEY,
  from_userid BIGINT, to_userid BIGINT,
  subject VARCHAR(255), body TEXT,
  is_read TINYINT DEFAULT 0,
  sent_at DATETIME DEFAULT NOW()
);
SQL
}

insert_data_on() {
  local idx=$1; local DB=$2
  local label
  [ "$ENV_MODE" = "server" ] && label="${SERVERS[$idx]}" || label="local"

  echo "  [${label}] Inserting users..."
  mysql_exec_on "$idx" << SQL
USE \`$DB\`;
INSERT INTO mdl_user (username, email, firstname, lastname, password, bio, city, country)
SELECT
  CONCAT('user_', UNIX_TIMESTAMP(NOW(6)), '_', seq),
  CONCAT('user_', UNIX_TIMESTAMP(NOW(6)), '_', seq, '@example.com'),
  ELT(1+FLOOR(RAND()*5),'Nguyen','Tran','Le','Pham','Hoang'),
  ELT(1+FLOOR(RAND()*5),'Van An','Thi Bich','Quoc Huy','Minh Duc','Thu Ha'),
  MD5(CONCAT('pass', seq, RAND())),
  REPEAT(CONCAT('Bio content ', seq, ' - Lorem ipsum dolor sit amet consectetur adipiscing elit. '), 5),
  ELT(1+FLOOR(RAND()*3),'Hanoi','HCM','Danang'), 'VN'
FROM ($(generate_seq $BATCH_USERS)) t;
SQL

  echo "  [${label}] Inserting courses..."
  mysql_exec_on "$idx" << SQL
USE \`$DB\`;
INSERT INTO mdl_course (fullname, shortname, summary, category, startdate, enddate)
SELECT
  CONCAT('Course ', UNIX_TIMESTAMP(NOW(6)), '_', seq, ': ', ELT(1+FLOOR(RAND()*5),'Mathematics','Physics','Chemistry','Biology','History')),
  CONCAT('CRS_', UNIX_TIMESTAMP(NOW(6)), '_', seq),
  REPEAT(CONCAT('Course summary ', seq, ' - Lorem ipsum dolor sit amet consectetur. '), 10),
  FLOOR(RAND()*10)+1,
  DATE_SUB(NOW(), INTERVAL FLOOR(RAND()*365) DAY),
  DATE_ADD(NOW(), INTERVAL FLOOR(RAND()*365) DAY)
FROM ($(generate_seq $BATCH_COURSES)) t;
SQL

  local MAX_USER MAX_COURSE
  MAX_USER=$(mysql_q_on "$idx" "SELECT MAX(id) FROM \`${DB}\`.mdl_user;" | tr -d '[:space:]')
  MAX_COURSE=$(mysql_q_on "$idx" "SELECT MAX(id) FROM \`${DB}\`.mdl_course;" | tr -d '[:space:]')

  echo "  [${label}] Inserting enrolments..."
  mysql_exec_on "$idx" << SQL
USE \`$DB\`;
INSERT INTO mdl_enrol (userid, courseid, status)
SELECT FLOOR(RAND()*${MAX_USER})+1, FLOOR(RAND()*${MAX_COURSE})+1, FLOOR(RAND()*2)
FROM ($(generate_seq $BATCH_ENROL)) t;
SQL

  echo "  [${label}] Inserting forum posts..."
  mysql_exec_on "$idx" << SQL
USE \`$DB\`;
INSERT INTO mdl_forum_posts (userid, courseid, subject, message)
SELECT
  FLOOR(RAND()*${MAX_USER})+1, FLOOR(RAND()*${MAX_COURSE})+1,
  CONCAT('Post subject ', seq),
  REPEAT(CONCAT('Forum content ', seq, ' - Lorem ipsum dolor sit amet. '), 20)
FROM ($(generate_seq $BATCH_FORUM)) t;
SQL

  echo "  [${label}] Inserting grades..."
  mysql_exec_on "$idx" << SQL
USE \`$DB\`;
INSERT INTO mdl_grade_grades (userid, courseid, itemid, finalgrade, feedback)
SELECT
  FLOOR(RAND()*${MAX_USER})+1, FLOOR(RAND()*${MAX_COURSE})+1,
  FLOOR(RAND()*100)+1, ROUND(RAND()*100, 2),
  CONCAT('Feedback: ', REPEAT('Good performance. Keep it up. ', 5))
FROM ($(generate_seq $BATCH_GRADES)) t;
SQL

  echo "  [${label}] Inserting assignments..."
  mysql_exec_on "$idx" << SQL
USE \`$DB\`;
INSERT INTO mdl_assign (userid, courseid, title, submission, grade, status)
SELECT
  FLOOR(RAND()*${MAX_USER})+1, FLOOR(RAND()*${MAX_COURSE})+1,
  CONCAT('Assignment ', seq, ': ', ELT(1+FLOOR(RAND()*4),'Essay','Report','Project','Lab Work')),
  REPEAT(CONCAT('Submission content for assignment ', seq, '. '), 15),
  ROUND(RAND()*100, 2),
  ELT(1+FLOOR(RAND()*3),'submitted','graded','draft')
FROM ($(generate_seq $BATCH_ASSIGN)) t;
SQL

  echo "  [${label}] Inserting quiz attempts..."
  mysql_exec_on "$idx" << SQL
USE \`$DB\`;
INSERT INTO mdl_quiz (userid, courseid, quiz_name, score, max_score, attempt, time_taken)
SELECT
  FLOOR(RAND()*${MAX_USER})+1, FLOOR(RAND()*${MAX_COURSE})+1,
  CONCAT('Quiz ', seq, ': ', ELT(1+FLOOR(RAND()*4),'Midterm','Final','Chapter Test','Practice')),
  ROUND(RAND()*10, 2), 10.00, FLOOR(RAND()*3)+1, FLOOR(RAND()*3600)+300
FROM ($(generate_seq $BATCH_QUIZ)) t;
SQL

  echo "  [${label}] Inserting messages..."
  mysql_exec_on "$idx" << SQL
USE \`$DB\`;
INSERT INTO mdl_message (from_userid, to_userid, subject, body, is_read)
SELECT
  FLOOR(RAND()*${MAX_USER})+1, FLOOR(RAND()*${MAX_USER})+1,
  CONCAT('Message ', seq, ': ', ELT(1+FLOOR(RAND()*4),'Question','Feedback','Announcement','Reminder')),
  REPEAT(CONCAT('Message body ', seq, ' - Dear student. '), 5),
  FLOOR(RAND()*2)
FROM ($(generate_seq $BATCH_MESSAGE)) t;
SQL

  echo "  [${label}] Inserting logs..."
  mysql_exec_on "$idx" << SQL
USE \`$DB\`;
INSERT INTO mdl_logstore (userid, courseid, action, target, ip, data)
SELECT
  FLOOR(RAND()*${MAX_USER})+1, FLOOR(RAND()*${MAX_COURSE})+1,
  ELT(1+FLOOR(RAND()*4),'viewed','created','updated','deleted'),
  ELT(1+FLOOR(RAND()*5),'course','user','forum','grade','assign'),
  CONCAT(FLOOR(RAND()*255),'.',FLOOR(RAND()*255),'.',FLOOR(RAND()*255),'.',FLOOR(RAND()*255)),
  REPEAT('Log context data. ', 8)
FROM ($(generate_seq $BATCH_LOGS)) t;
SQL

  ok "[${label}] Done: $DB"
}

# =========================================
# Chạy gen song song trên tất cả server
# =========================================
run_gen_parallel() {
  local DB=$1
  local run_count=$SERVER_COUNT
  [ "$ENV_MODE" = "local" ] && run_count=1

  echo ""
  sep
  echo -e "  ${BOLD}DB:${NC} $DB  (${run_count} server song song)"
  sep

  local pids=()
  for i in $(seq 0 $((run_count - 1))); do
    (
      setup_tables_on "$i" "$DB"
      insert_data_on  "$i" "$DB"
    ) &
    pids+=($!)
  done
  for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done
}

# =========================================
# MAIN
# =========================================
echo ""
echo -e "${BOLD}  Moodle Data Generator${NC}"
echo ""

# Bước 1: Môi trường (loop cho đến khi ok)
while true; do
  setup_env && break
done

# Bước 2: Runtime (b → quay lại chọn env)
while true; do
  setup_runtime && break
  # Nếu chọn b → quay lại chọn env
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
sep

# Bước 3: Menu gen data
while true; do
  ask_mode

  while true; do
    case "$MODE" in
      existing) select_existing; step2=$? ;;
      new)      select_new;      step2=$? ;;
    esac

    [ "$step2" -eq 1 ] && break

    echo ""
    echo -e "  ${BOLD}Started: $(date '+%Y-%m-%d %H:%M:%S')${NC}"

    for DB in "${TARGET_DBS[@]}"; do
      run_gen_parallel "$DB"
    done

    echo ""
    echo -e "  ${BOLD}Done: $(date '+%Y-%m-%d %H:%M:%S')${NC}"
    echo ""

    read -rp "  Tiếp tục gen? [y/q]: " again
    case "$again" in
      y|Y) break ;;
      *)   quit ;;
    esac
    break
  done
done
