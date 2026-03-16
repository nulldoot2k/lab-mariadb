#!/bin/bash

# ============================================================
#  MOODLE DATA GENERATOR
#  Chạy: bash generate_moodle_db.sh
# ============================================================

CONTAINER="mariadb-104"
MYSQL_USER="root"
MYSQL_PASS="rootpassword"

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
# Helper
# =========================================
mysql_exec() {
  docker exec -i "$CONTAINER" \
    mysql -u"$MYSQL_USER" -p"$MYSQL_PASS" 2>/dev/null
}

mysql_q() {
  docker exec "$CONTAINER" \
    mysql -u"$MYSQL_USER" -p"$MYSQL_PASS" -N 2>/dev/null \
    -e "$1"
}

gen_uuid() {
  cat /proc/sys/kernel/random/uuid 2>/dev/null \
    || python3 -c "import uuid; print(uuid.uuid4())" 2>/dev/null
}

# =========================================
# Kiểm tra container
# =========================================
check_container() {
  echo -e "  Kiểm tra container ${BOLD}${CONTAINER}${NC}..."
  if [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" != "true" ]; then
    fail "Container '$CONTAINER' không đang chạy."; exit 1
  fi
  if ! mysql_q "SELECT 1;" &>/dev/null; then
    fail "Không kết nối được MariaDB."; exit 1
  fi
  ok "Container ready."
}

# =========================================
# Load DB hiện có
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
# Bước 1: Menu chính
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

# =========================================
# Bước 2a: Chọn DB có sẵn
# =========================================
select_existing() {
  load_databases

  if [ ${#EXISTING_DBS[@]} -eq 0 ]; then
    echo ""
    warn "Chưa có DB nào trên server."
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
    echo -e "  ${BOLD}DB hiện có trên ${CONTAINER}${NC}"
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
         [ "$choice" -ge 1 ] && \
         [ "$choice" -le "${#EXISTING_DBS[@]}" ]; then
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

# =========================================
# Bước 2b: Tạo DB mới
# =========================================
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

    if [[ "$input" =~ ^[0-9]+$ ]] && \
       [ "$input" -ge 1 ] && [ "$input" -le 20 ]; then
      TARGET_DBS=()
      echo ""
      for (( i=0; i<input; i++ )); do
        local uuid
        uuid=$(gen_uuid)
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
# Setup tables
# =========================================
setup_tables() {
  local DB=$1
  log "Setup tables..."
  mysql_exec << SQL
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

# =========================================
# Insert data
# =========================================
insert_data() {
  local DB=$1

  log "Inserting $BATCH_USERS users..."
  mysql_exec << SQL
USE \`$DB\`;
INSERT INTO mdl_user (username, email, firstname, lastname, password, bio, city, country)
SELECT
  CONCAT('user_', UNIX_TIMESTAMP(NOW(6)), '_', seq),
  CONCAT('user_', UNIX_TIMESTAMP(NOW(6)), '_', seq, '@example.com'),
  ELT(1+FLOOR(RAND()*5),'Nguyen','Tran','Le','Pham','Hoang'),
  ELT(1+FLOOR(RAND()*5),'Van An','Thi Bich','Quoc Huy','Minh Duc','Thu Ha'),
  MD5(CONCAT('pass', seq, RAND())),
  REPEAT(CONCAT('Bio content ', seq, ' - Lorem ipsum dolor sit amet consectetur adipiscing elit. '), 5),
  ELT(1+FLOOR(RAND()*3),'Hanoi','HCM','Danang'),
  'VN'
FROM ($(generate_seq $BATCH_USERS)) t;
SQL

  log "Inserting $BATCH_COURSES courses..."
  mysql_exec << SQL
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

  log "Caching MAX ids..."
  MAX_USER=$(mysql_q "SELECT MAX(id) FROM \`${DB}\`.mdl_user;" | tr -d '[:space:]')
  MAX_COURSE=$(mysql_q "SELECT MAX(id) FROM \`${DB}\`.mdl_course;" | tr -d '[:space:]')
  log "MAX_USER=$MAX_USER  MAX_COURSE=$MAX_COURSE"

  log "Inserting $BATCH_ENROL enrolments..."
  mysql_exec << SQL
USE \`$DB\`;
INSERT INTO mdl_enrol (userid, courseid, status)
SELECT FLOOR(RAND()*${MAX_USER})+1, FLOOR(RAND()*${MAX_COURSE})+1, FLOOR(RAND()*2)
FROM ($(generate_seq $BATCH_ENROL)) t;
SQL

  log "Inserting $BATCH_FORUM forum posts..."
  mysql_exec << SQL
USE \`$DB\`;
INSERT INTO mdl_forum_posts (userid, courseid, subject, message)
SELECT
  FLOOR(RAND()*${MAX_USER})+1,
  FLOOR(RAND()*${MAX_COURSE})+1,
  CONCAT('Post subject ', seq),
  REPEAT(CONCAT('Forum content ', seq, ' - Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. '), 20)
FROM ($(generate_seq $BATCH_FORUM)) t;
SQL

  log "Inserting $BATCH_GRADES grades..."
  mysql_exec << SQL
USE \`$DB\`;
INSERT INTO mdl_grade_grades (userid, courseid, itemid, finalgrade, feedback)
SELECT
  FLOOR(RAND()*${MAX_USER})+1,
  FLOOR(RAND()*${MAX_COURSE})+1,
  FLOOR(RAND()*100)+1,
  ROUND(RAND()*100, 2),
  CONCAT('Feedback: ', REPEAT('Good performance. Keep it up. ', 5))
FROM ($(generate_seq $BATCH_GRADES)) t;
SQL

  log "Inserting $BATCH_ASSIGN assignments..."
  mysql_exec << SQL
USE \`$DB\`;
INSERT INTO mdl_assign (userid, courseid, title, submission, grade, status)
SELECT
  FLOOR(RAND()*${MAX_USER})+1,
  FLOOR(RAND()*${MAX_COURSE})+1,
  CONCAT('Assignment ', seq, ': ', ELT(1+FLOOR(RAND()*4),'Essay','Report','Project','Lab Work')),
  REPEAT(CONCAT('Submission content for assignment ', seq, '. Student work: Lorem ipsum dolor sit amet. '), 15),
  ROUND(RAND()*100, 2),
  ELT(1+FLOOR(RAND()*3),'submitted','graded','draft')
FROM ($(generate_seq $BATCH_ASSIGN)) t;
SQL

  log "Inserting $BATCH_QUIZ quiz attempts..."
  mysql_exec << SQL
USE \`$DB\`;
INSERT INTO mdl_quiz (userid, courseid, quiz_name, score, max_score, attempt, time_taken)
SELECT
  FLOOR(RAND()*${MAX_USER})+1,
  FLOOR(RAND()*${MAX_COURSE})+1,
  CONCAT('Quiz ', seq, ': ', ELT(1+FLOOR(RAND()*4),'Midterm','Final','Chapter Test','Practice')),
  ROUND(RAND()*10, 2),
  10.00,
  FLOOR(RAND()*3)+1,
  FLOOR(RAND()*3600)+300
FROM ($(generate_seq $BATCH_QUIZ)) t;
SQL

  log "Inserting $BATCH_MESSAGE messages..."
  mysql_exec << SQL
USE \`$DB\`;
INSERT INTO mdl_message (from_userid, to_userid, subject, body, is_read)
SELECT
  FLOOR(RAND()*${MAX_USER})+1,
  FLOOR(RAND()*${MAX_USER})+1,
  CONCAT('Message ', seq, ': ', ELT(1+FLOOR(RAND()*4),'Question','Feedback','Announcement','Reminder')),
  REPEAT(CONCAT('Message body ', seq, ' - Dear student, please note that Lorem ipsum dolor sit amet. '), 5),
  FLOOR(RAND()*2)
FROM ($(generate_seq $BATCH_MESSAGE)) t;
SQL

  log "Inserting $BATCH_LOGS logs..."
  mysql_exec << SQL
USE \`$DB\`;
INSERT INTO mdl_logstore (userid, courseid, action, target, ip, data)
SELECT
  FLOOR(RAND()*${MAX_USER})+1,
  FLOOR(RAND()*${MAX_COURSE})+1,
  ELT(1+FLOOR(RAND()*4),'viewed','created','updated','deleted'),
  ELT(1+FLOOR(RAND()*5),'course','user','forum','grade','assign'),
  CONCAT(FLOOR(RAND()*255),'.',FLOOR(RAND()*255),'.',FLOOR(RAND()*255),'.',FLOOR(RAND()*255)),
  REPEAT('Log context data. ', 8)
FROM ($(generate_seq $BATCH_LOGS)) t;
SQL

  ok "Done: $DB"
}

# =========================================
# MAIN
# =========================================
echo ""
echo -e "${BOLD}  Moodle Data Generator${NC}"
dim   "  Container: ${CONTAINER}"
echo ""

check_container

while true; do
  ask_mode

  while true; do
    case "$MODE" in
      existing) select_existing; step2=$? ;;
      new)      select_new;      step2=$? ;;
    esac

    [ "$step2" -eq 1 ] && break

    # Chạy gen
    echo ""
    echo -e "  ${BOLD}Started: $(date '+%Y-%m-%d %H:%M:%S')${NC}"

    for DB in "${TARGET_DBS[@]}"; do
      echo ""
      sep
      echo -e "  ${BOLD}DB:${NC} $DB"
      sep
      setup_tables "$DB"
      insert_data  "$DB"
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
