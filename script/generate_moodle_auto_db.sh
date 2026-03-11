#!/bin/bash

# ============================================================
#  AUTO ACTIVITY GENERATOR — Moodle
#  Chạy: bash insert_auto.sh
#  → Tự detect DB từ MariaDB, hỏi chọn rồi bắt đầu insert
# ============================================================

CONTAINER="mariadb-104"
MYSQL_USER="root"
MYSQL_PASS="rootpassword"

INTERVAL=5
USERS_PER_TICK=5

# =========================================
# Colors
# =========================================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

ok()   { echo -e "  ${GREEN}✔ $1${NC}"; }
fail() { echo -e "  ${RED}✘ $1${NC}"; }
warn() { echo -e "  ${YELLOW}⚠ $1${NC}"; }
info() { echo -e "  ${CYAN}ℹ $1${NC}"; }

# =========================================
# Helper
# =========================================
mysql_exec() {
  docker exec -i "$CONTAINER" \
    mysql -u"$MYSQL_USER" -p"$MYSQL_PASS" -N 2>/dev/null
}

mysql_q() {
  docker exec "$CONTAINER" \
    mysql -u"$MYSQL_USER" -p"$MYSQL_PASS" -N 2>/dev/null \
    -e "$1"
}

get_max() {
  mysql_q "SELECT COALESCE(MAX(id),0) FROM \`$1\`.\`$2\`;" | tr -d '[:space:]'
}

# =========================================
# Kiểm tra container + kết nối
# =========================================
check_container() {
  echo -e "  Kiểm tra container ${BOLD}${CONTAINER}${NC}..."

  if ! docker inspect "$CONTAINER" &>/dev/null; then
    fail "Container '${CONTAINER}' không tồn tại."; exit 1
  fi
  if [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" != "true" ]; then
    fail "Container '${CONTAINER}' không đang chạy."; exit 1
  fi
  if ! mysql_q "SELECT 1;" &>/dev/null; then
    fail "Không kết nối được MariaDB — kiểm tra user/pass."; exit 1
  fi

  ok "Container ready."
}

# =========================================
# Load danh sách DB từ MariaDB
# Lọc bỏ các system DB
# =========================================
load_databases() {
  echo -e "  Đang load danh sách DB từ MariaDB..."

  mapfile -t ALL_DATABASES < <(
    mysql_q "SELECT schema_name
             FROM information_schema.schemata
             WHERE schema_name NOT IN (
               'information_schema','performance_schema',
               'mysql','sys','innodb'
             )
             ORDER BY schema_name;"
  )

  if [ ${#ALL_DATABASES[@]} -eq 0 ]; then
    fail "Không tìm thấy DB nào (ngoài system DB)."; exit 1
  fi

  ok "Tìm thấy ${#ALL_DATABASES[@]} DB."
}

# =========================================
# Hiển thị info nhanh từng DB (user/course count)
# =========================================
db_info() {
  local DB=$1
  local mu mc
  mu=$(get_max "$DB" "mdl_user"   2>/dev/null || echo "?")
  mc=$(get_max "$DB" "mdl_course" 2>/dev/null || echo "?")
  # Chỉ show nếu có mdl_user
  if [[ "$mu" =~ ^[0-9]+$ ]] && [ "$mu" -gt 0 ]; then
    echo "users≈${mu}  courses≈${mc}"
  else
    echo "chưa có data Moodle"
  fi
}

# =========================================
# Hỏi chọn DB — load động từ server
# =========================================
select_db() {
  echo ""
  echo -e "${BOLD}  ┌─ Danh sách DB trên ${CONTAINER} ─────────────────────┐${NC}"

  # Hiển thị từng DB kèm info
  for i in "${!ALL_DATABASES[@]}"; do
    local DB="${ALL_DATABASES[$i]}"
    local info
    info=$(db_info "$DB")
    printf "  │  ${CYAN}%2d)${NC}  %-38s  ${YELLOW}%s${NC}\n" \
      "$((i+1))" "$DB" "$info"
  done

  echo -e "${BOLD}  │${NC}"
  printf   "  │  ${CYAN}%2s)${NC}  %s\n" "0" "Tất cả (${#ALL_DATABASES[@]} DB)"
  echo -e "${BOLD}  └─────────────────────────────────────────────────────┘${NC}"
  echo ""

  while true; do
    read -rp "  Nhập số [0-${#ALL_DATABASES[@]}]: " choice
    if [[ "$choice" == "0" ]]; then
      SELECTED_DBS=("${ALL_DATABASES[@]}")
      break
    elif [[ "$choice" =~ ^[0-9]+$ ]] && \
         [ "$choice" -ge 1 ] && \
         [ "$choice" -le "${#ALL_DATABASES[@]}" ]; then
      SELECTED_DBS=("${ALL_DATABASES[$((choice-1))]}")
      break
    else
      warn "Nhập số từ 0 đến ${#ALL_DATABASES[@]}."
    fi
  done

  echo ""
  info "Đã chọn ${#SELECTED_DBS[@]} DB:"
  for DB in "${SELECTED_DBS[@]}"; do
    info "  → $DB"
  done
}

# =========================================
# Kiểm tra DB được chọn có data Moodle không
# =========================================
check_selected() {
  local all_ok=1
  echo ""
  for DB in "${SELECTED_DBS[@]}"; do
    local mu mc
    mu=$(get_max "$DB" "mdl_user")
    mc=$(get_max "$DB" "mdl_course")
    if [[ "${mu:-0}" -le 0 ]] || [[ "${mc:-0}" -le 0 ]]; then
      warn "DB ${DB:0:8}…  chưa có data — chạy generate_moodle_db.sh trước."
      all_ok=0
    else
      ok "DB ${DB:0:8}…  users=${mu}  courses=${mc}  ✓"
    fi
  done
  [ "$all_ok" -eq 0 ] && exit 1
}

# =========================================
# 1 tick — toàn bộ trong 1 connection
# =========================================
do_tick() {
  local DB=$1
  local MU MC
  MU=$(get_max "$DB" "mdl_user")
  MC=$(get_max "$DB" "mdl_course")

  [ "${MU:-0}" -le 0 ] && { warn "Không có user trong ${DB:0:8}…"; return 1; }
  [ "${MC:-0}" -le 0 ] && { warn "Không có course trong ${DB:0:8}…"; return 1; }

  mysql_exec << SQL
USE \`${DB}\`;

-- 1. VIEW events
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

-- 2. Login/logout
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

-- 3. Forum post
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

-- 4. Assignment
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

-- 5. Quiz
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

-- 6. Message
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

-- 7. Grade update — dùng id range, không ORDER BY RAND()
SET @gmax := (SELECT MAX(id) FROM mdl_grade_grades);
UPDATE mdl_grade_grades
SET finalgrade = ROUND(RAND()*100,2),
    feedback   = CONCAT('Auto-graded ',DATE_FORMAT(NOW(),'%Y-%m-%d %H:%i:%s')),
    created_at = NOW()
WHERE id BETWEEN FLOOR(RAND()*@gmax)+1
              AND FLOOR(RAND()*@gmax)+4;

-- 8. Enrol status — tương tự
SET @emax := (SELECT MAX(id) FROM mdl_enrol);
UPDATE mdl_enrol
SET status      = FLOOR(RAND()*2),
    enrolled_at = NOW()
WHERE id BETWEEN FLOOR(RAND()*@emax)+1
              AND FLOOR(RAND()*@emax)+3;
SQL
}

# =========================================
# Quick count dùng information_schema (O(1))
# =========================================
quick_count() {
  local DB=$1
  mysql_q "SELECT COALESCE(SUM(table_rows),0)
           FROM information_schema.tables
           WHERE table_schema='${DB}'
             AND table_name IN (
               'mdl_logstore','mdl_forum_posts',
               'mdl_assign','mdl_quiz','mdl_message'
             );" | tr -d '[:space:]'
}

# =========================================
# Trap Ctrl+C
# =========================================
TICK=0
START_TS=$(date +%s)

cleanup() {
  echo ""
  local ELAPSED=$(( $(date +%s) - START_TS ))
  echo ""
  echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}  Dừng — Summary${NC}"
  printf   "  Thời gian : %02d:%02d:%02d\n" \
    $((ELAPSED/3600)) $((ELAPSED%3600/60)) $((ELAPSED%60))
  echo     "  Tổng tick : ${TICK}"
  echo ""
  for DB in "${SELECTED_DBS[@]}"; do
    TOTAL=$(quick_count "$DB")
    echo "  DB ${DB:0:8}…  activity rows ≈ ${TOTAL:-?}"
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
echo    "  Container : ${CONTAINER}"
echo    "  Interval  : ${INTERVAL}s / tick  |  User/tick : ${USERS_PER_TICK}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${NC}"

check_container
load_databases
select_db
check_selected

echo ""
echo -e "  Bắt đầu. Nhấn ${BOLD}Ctrl+C${NC} để dừng."
echo ""

while true; do
  TICK=$((TICK+1))
  echo -e "  ── ${CYAN}Tick #${TICK}${NC}  $(date '+%H:%M:%S')  ─────────────────────────────"

  for DB in "${SELECTED_DBS[@]}"; do
    if do_tick "$DB"; then
      TOTAL=$(quick_count "$DB")
      ok "DB ${DB:0:8}…  activity ≈ ${TOTAL:-?} rows"
    else
      fail "DB ${DB:0:8}…  lỗi tick"
    fi
  done

  echo ""
  sleep "$INTERVAL"
done
