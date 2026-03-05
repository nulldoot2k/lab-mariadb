#!/bin/bash

# ============================================================
#  AUTO ACTIVITY GENERATOR
#  Mô phỏng user hoạt động trên Moodle mỗi 5 giây:
#    - View course / page
#    - Post forum
#    - Submit assignment
#    - Take quiz
#    - Send message
#    - Grade update (system)
#    - Logstore: login / logout / navigate
# ============================================================

# =========================================
# Config — chỉnh tại đây
# =========================================
CONTAINER="mariadb-104"
MYSQL_USER="root"
MYSQL_PASS="rootpassword"
DATABASES=(
  "cbb395d7-5ba7-4bb1-b89b-23b71d4051b4"
  "50006e43-0daa-4c0d-8815-040a570a3940"
)

INTERVAL=5           # giây giữa mỗi tick
USERS_PER_TICK=5     # số lượt user hoạt động mỗi tick
LOG_FILE=""          # path ghi log file, để trống = tắt

# =========================================
# Colors
# =========================================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; BOLD='\033[1m'; NC='\033[0m'

ok()     { echo -e "  ${GREEN}✅ $1${NC}"; }
fail()   { echo -e "  ${RED}❌ $1${NC}"; }
warn()   { echo -e "  ${YELLOW}⚠️  $1${NC}"; }

flog() { [ -n "$LOG_FILE" ] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"; }

# =========================================
# Helper SQL
# =========================================
mysql_q() {
    docker exec -i "$CONTAINER" mysql -u"$MYSQL_USER" -p"$MYSQL_PASS" -N 2>/dev/null
}

get_max() {
    # Lấy MAX(id) của bảng, trả về ít nhất 1
    local DB=$1 TBL=$2
    local val
    val=$(echo "SELECT COALESCE(MAX(id),1) FROM \`${DB}\`.\`${TBL}\`;" | mysql_q)
    echo "${val:-1}"
}

# =========================================
# Tick: 1 vòng activity cho 1 DB
# =========================================
do_tick() {
    local DB=$1
    local TS
    TS=$(date '+%Y-%m-%d %H:%M:%S')

    local MU MC
    MU=$(get_max "$DB" "mdl_user")
    MC=$(get_max "$DB" "mdl_course")

    if [ "${MU}" -le 1 ] || [ "${MC}" -le 1 ]; then
        warn "DB ${DB:0:8}… — chưa có data, bỏ qua tick (chạy generate_moodle_db.sh trước)."
        return 0
    fi

    mysql_q << SQL
USE \`${DB}\`;

-- ── 1. VIEW COURSE / MODULE / PAGE ──────────────────────
INSERT INTO mdl_logstore (userid, courseid, action, target, ip, data, created_at)
SELECT
  FLOOR(RAND() * ${MU}) + 1,
  FLOOR(RAND() * ${MC}) + 1,
  'viewed',
  ELT(1 + FLOOR(RAND()*5), 'course','module','page','resource','block'),
  CONCAT(
    FLOOR(RAND()*223)+1, '.',
    FLOOR(RAND()*255),   '.',
    FLOOR(RAND()*255),   '.',
    FLOOR(RAND()*254)+1
  ),
  CONCAT('{"ts":"${TS}","sid":"', LEFT(MD5(RAND()),16), '","dur":', FLOOR(RAND()*600)+10, '}'),
  NOW()
FROM (
  SELECT 1 AS n UNION SELECT 2 UNION SELECT 3
  UNION SELECT 4 UNION SELECT 5
) gen
LIMIT ${USERS_PER_TICK};

-- ── 2. LOGIN / LOGOUT ────────────────────────────────────
INSERT INTO mdl_logstore (userid, courseid, action, target, ip, data, created_at)
SELECT
  FLOOR(RAND() * ${MU}) + 1,
  0,
  ELT(1 + FLOOR(RAND()*2), 'loggedin', 'loggedout'),
  'user',
  CONCAT(
    FLOOR(RAND()*223)+1, '.',
    FLOOR(RAND()*255),   '.',
    FLOOR(RAND()*255),   '.',
    FLOOR(RAND()*254)+1
  ),
  CONCAT('{"ua":"Mozilla/5.0 Chrome/","at":"${TS}"}'),
  NOW()
FROM (SELECT 1 UNION SELECT 2 UNION SELECT 3) gen
LIMIT 3;

-- ── 3. FORUM POST ────────────────────────────────────────
INSERT INTO mdl_forum_posts (userid, courseid, subject, message, created_at)
SELECT
  FLOOR(RAND() * ${MU}) + 1,
  FLOOR(RAND() * ${MC}) + 1,
  CONCAT(
    ELT(1 + FLOOR(RAND()*6),
      'Hỏi về','Thảo luận:','Re:','Góp ý:','Câu hỏi:','Nhờ tư vấn:'),
    ' ',
    ELT(1 + FLOOR(RAND()*6),
      'bài tập tuần này','deadline nộp bài','tài liệu tham khảo',
      'bài kiểm tra','dự án nhóm','điểm danh'),
    ' [', LEFT('${TS}', 16), ']'
  ),
  CONCAT(
    ELT(1 + FLOOR(RAND()*4),
      'Mình không hiểu phần này, thầy/cô có thể giải thích thêm không ạ?',
      'Bài tập có thể nộp muộn không? Mình đang bị ốm.',
      'Cảm ơn thầy, mình đã hiểu bài hơn rồi ạ!',
      'Nhờ các bạn trong nhóm review giúp bài của mình với.'
    )
  ),
  NOW()
FROM (SELECT 1 UNION SELECT 2) gen;

-- ── 4. ASSIGNMENT SUBMISSION ─────────────────────────────
INSERT INTO mdl_assign (userid, courseid, title, submission, grade, status, submitted_at)
SELECT
  FLOOR(RAND() * ${MU}) + 1,
  FLOOR(RAND() * ${MC}) + 1,
  CONCAT('Bài nộp – ', LEFT('${TS}', 16)),
  CONCAT(
    ELT(1 + FLOOR(RAND()*3),
      'Phân tích vấn đề: ','Kết quả nghiên cứu: ','Giải pháp đề xuất: '),
    REPEAT('Lorem ipsum dolor sit amet, consectetur adipiscing elit. ', 4)
  ),
  ROUND(RAND() * 100, 2),
  ELT(1 + FLOOR(RAND()*3), 'submitted', 'graded', 'draft'),
  NOW()
FROM (SELECT 1 UNION SELECT 2) gen;

-- ── 5. QUIZ ATTEMPT ──────────────────────────────────────
INSERT INTO mdl_quiz (userid, courseid, quiz_name, score, max_score, attempt, time_taken, started_at)
SELECT
  FLOOR(RAND() * ${MU}) + 1,
  FLOOR(RAND() * ${MC}) + 1,
  CONCAT(
    ELT(1 + FLOOR(RAND()*4), 'Kiểm tra nhanh','Ôn tập','Quiz thực hành','Bài thi thử'),
    ' – ', LEFT('${TS}', 16)
  ),
  ROUND(RAND() * 10, 2),
  10.00,
  FLOOR(RAND() * 3) + 1,
  FLOOR(RAND() * 1800) + 60,
  NOW()
FROM (SELECT 1 UNION SELECT 2) gen;

-- ── 6. PRIVATE MESSAGE ───────────────────────────────────
INSERT INTO mdl_message (from_userid, to_userid, subject, body, is_read, sent_at)
SELECT
  FLOOR(RAND() * ${MU}) + 1,
  FLOOR(RAND() * ${MU}) + 1,
  CONCAT(
    ELT(1 + FLOOR(RAND()*4), 'Hỏi bài','Nhờ giúp đỡ','Thông báo','Nhắc nhở'),
    ' – ', LEFT('${TS}', 16)
  ),
  ELT(1 + FLOOR(RAND()*4),
    'Bạn ơi cho mình hỏi bài tập tuần này làm thế nào vậy?',
    'Mình cần giúp đỡ phần bài tập lớn, bạn có thời gian không?',
    'Nhắc bạn nộp bài trước deadline ngày mai nhé!',
    'Nhóm mình họp lúc 8h tối nay, bạn có online không?'
  ),
  FLOOR(RAND() * 2),
  NOW()
FROM (SELECT 1 UNION SELECT 2) gen;

-- ── 7. GRADE UPDATE (hệ thống chấm ngầm) ────────────────
UPDATE mdl_grade_grades
SET
  finalgrade = ROUND(RAND() * 100, 2),
  feedback   = CONCAT('Auto-graded at ${TS}.'),
  created_at = NOW()
WHERE id IN (
  SELECT id FROM (
    SELECT id FROM mdl_grade_grades ORDER BY RAND() LIMIT 3
  ) _tmp
);

-- ── 8. ENROL STATUS CHANGE ───────────────────────────────
UPDATE mdl_enrol
SET
  status      = FLOOR(RAND() * 2),
  enrolled_at = NOW()
WHERE id IN (
  SELECT id FROM (
    SELECT id FROM mdl_enrol ORDER BY RAND() LIMIT 2
  ) _tmp
);
SQL
}

# =========================================
# Đếm nhanh tổng row activity để hiển thị
# =========================================
quick_count() {
    local DB=$1
    echo "SELECT
      (SELECT COUNT(*) FROM \`${DB}\`.mdl_logstore)
    + (SELECT COUNT(*) FROM \`${DB}\`.mdl_forum_posts)
    + (SELECT COUNT(*) FROM \`${DB}\`.mdl_assign)
    + (SELECT COUNT(*) FROM \`${DB}\`.mdl_quiz)
    + (SELECT COUNT(*) FROM \`${DB}\`.mdl_message)
    AS t;" | mysql_q
}

# =========================================
# Kiểm tra container
# =========================================
check_container() {
    if ! docker inspect "$CONTAINER" &>/dev/null; then
        fail "Container '${CONTAINER}' không tồn tại."; exit 1
    fi
    if [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" != "true" ]; then
        fail "Container '${CONTAINER}' không đang chạy."; exit 1
    fi
    echo "SELECT 1;" | mysql_q > /dev/null 2>&1 \
        || { fail "Không kết nối được MariaDB — kiểm tra user/pass."; exit 1; }
}

# =========================================
# Trap Ctrl+C → summary
# =========================================
TICK=0
START_TS=$(date +%s)

cleanup() {
    echo ""
    echo ""
    local ELAPSED=$(( $(date +%s) - START_TS ))
    echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}  Dừng Auto Generator${NC}"
    printf "  Đã chạy : %02d:%02d:%02d\n" $((ELAPSED/3600)) $((ELAPSED%3600/60)) $((ELAPSED%60))
    echo    "  Tổng tick: ${TICK}"
    echo ""
    for DB in "${DATABASES[@]}"; do
        TOTAL=$(quick_count "$DB")
        echo "  DB ${DB:0:8}… → tổng activity rows: ${TOTAL:-?}"
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
echo    "  Interval  : ${INTERVAL}s / tick"
echo    "  DBs       : ${#DATABASES[@]}"
echo    "  User/tick : ${USERS_PER_TICK}"
[ -n "$LOG_FILE" ] && echo "  Log file  : ${LOG_FILE}" || echo "  Log file  : (tắt)"
echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Nhấn ${BOLD}Ctrl+C${NC} để dừng."
echo ""

check_container
ok "Container '${CONTAINER}' ready."
echo ""

while true; do
    TICK=$((TICK + 1))
    TS_NOW=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "  ── ${CYAN}Tick #${TICK}${NC}  ${TS_NOW}  ──────────────────────────────────"

    for DB in "${DATABASES[@]}"; do
        if do_tick "$DB" 2>/dev/null; then
            TOTAL=$(quick_count "$DB")
            ok "DB ${DB:0:8}…  activity rows tích lũy: ${TOTAL:-?}"
            flog "TICK=${TICK} DB=${DB} OK total=${TOTAL}"
        else
            fail "DB ${DB:0:8}…  lỗi khi insert activity"
            flog "TICK=${TICK} DB=${DB} FAIL"
        fi
    done

    echo ""
    sleep "$INTERVAL"
done
