#!/bin/bash
set -euo pipefail

# ============================================================
#  CRON BACKUP + VERIFY RESTORE + TELEGRAM NOTIFY
#
#  Luồng:
#    1. Chọn backup full (tất cả DB) hay 1 DB cụ thể
#    2. Nhập thông tin source: docker container / systemd service
#    3. Nhập tên verify container:
#       - Nếu đã tồn tại + đang chạy → dùng luôn
#       - Nếu chưa có → tự docker run (image lấy từ source container
#         hoặc mariadb:10.4), xong thì tự stop + rm khi script kết thúc
#    4. Với mỗi DB:
#       a. Dump → .sql.gz + MD5
#       b. Kiểm tra MD5
#       c. Restore thử vào DB tạm trên verify container
#       d. So sánh row count source vs restored
#       e. Drop DB tạm
#    5. Notify Telegram 1 lần duy nhất khi hoàn tất toàn bộ
#    6. Tự cleanup verify container (nếu script tạo)
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
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

ok()   { echo -e "  ${GREEN}✅ $1${NC}"; }
fail() { echo -e "  ${RED}❌ $1${NC}"; }
info() { echo -e "  ${CYAN}   $1${NC}"; }
warn() { echo -e "  ${YELLOW}⚠️  $1${NC}"; }
step() { echo -e "\n${CYAN}$1${NC}"; echo "  ────────────────────────────────────────────────────"; }

# =========================================
# Verify container: tự tạo nếu chưa có
# =========================================
VRF_CREATED=false      # flag: script có tự tạo container không
VRF_USER="root"
VRF_PASS="Verify_Tmp_$(date +%s)"   # password ngẫu nhiên cho container tạm

setup_verify_container() {
    local CTR="$1"

    # Xác định image: ưu tiên lấy từ source container (nếu docker mode)
    local IMAGE="mariadb:10.4"
    if [ "$SRC_MODE" = "1" ]; then
        local SRC_IMAGE
        SRC_IMAGE=$(docker inspect -f '{{.Config.Image}}' "$SRC_CTR" 2>/dev/null || true)
        [ -n "$SRC_IMAGE" ] && IMAGE="$SRC_IMAGE"
    fi

    info "Tự tạo verify container '${CTR}' (image: ${IMAGE})..."
    docker run -d \
        --name "$CTR" \
        -e MYSQL_ROOT_PASSWORD="$VRF_PASS" \
        -e MYSQL_ROOT_HOST="%" \
        "$IMAGE" \
        --character-set-server=utf8mb4 \
        --collation-server=utf8mb4_unicode_ci \
        > /dev/null 2>&1 \
        || { fail "docker run thất bại — kiểm tra Docker daemon."; exit 1; }

    VRF_CREATED=true
    info "Đợi MariaDB trong '${CTR}' sẵn sàng..."
    local RETRY=0
    until docker exec "$CTR" mysql -u"$VRF_USER" -p"$VRF_PASS" \
            -e "SELECT 1;" > /dev/null 2>&1; do
        RETRY=$((RETRY + 1))
        [ "$RETRY" -ge 30 ] && { fail "Timeout — container verify không start được sau 30s."; exit 1; }
        sleep 1
        printf "."
    done
    echo ""
    ok "Verify container '${CTR}' ready (${RETRY}s)."
}

# Cleanup: stop + rm verify container nếu script tự tạo
cleanup_verify() {
    if [ "$VRF_CREATED" = true ]; then
        echo ""
        info "Cleanup: dừng và xóa verify container '${VRF_CTR}'..."
        docker stop "$VRF_CTR" > /dev/null 2>&1 || true
        docker rm   "$VRF_CTR" > /dev/null 2>&1 || true
        ok "Đã xóa verify container '${VRF_CTR}'."
    fi
}
trap cleanup_verify EXIT

# =========================================
# Parse tần suất → giây
#   Hỗ trợ: 30m  2h  1d  7d  2w  1y
#   m=phút  h=giờ  d=ngày  w=tuần  y=năm
# =========================================
parse_interval() {
    local RAW="$1"
    local NUM UNIT

    # Tách số và đơn vị (vd: "30m" → NUM=30 UNIT=m)
    NUM=$(echo "$RAW" | grep -oP '^\d+')
    UNIT=$(echo "$RAW" | grep -oP '[a-zA-Z]+$' | tr '[:upper:]' '[:lower:]')

    if [ -z "$NUM" ] || [ -z "$UNIT" ]; then
        echo "0"; return 1
    fi

    case "$UNIT" in
        m|min)    echo $((NUM * 60)) ;;
        h|hour)   echo $((NUM * 3600)) ;;
        d|day)    echo $((NUM * 86400)) ;;
        w|week)   echo $((NUM * 604800)) ;;
        y|year)   echo $((NUM * 31536000)) ;;
        *)        echo "0"; return 1 ;;
    esac
}

interval_label() {
    local RAW="$1"
    local NUM UNIT
    NUM=$(echo "$RAW" | grep -oP '^\d+')
    UNIT=$(echo "$RAW" | grep -oP '[a-zA-Z]+$' | tr '[:upper:]' '[:lower:]')
    case "$UNIT" in
        m|min)   echo "${NUM} phút" ;;
        h|hour)  echo "${NUM} giờ" ;;
        d|day)   echo "${NUM} ngày" ;;
        w|week)  echo "${NUM} tuần" ;;
        y|year)  echo "${NUM} năm" ;;
        *)       echo "$RAW" ;;
    esac
}

# =========================================
# Chạy 1 cycle backup (dump + verify + notify)
# =========================================
run_backup_cycle() {
    local CYCLE="$1"

    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}  CYCLE #${CYCLE}  —  $(date '+%Y-%m-%d %H:%M:%S')${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${NC}"

    # Reset RESULTS cho mỗi cycle
    RESULTS=()

    # Lấy lại danh sách DB (full mode: re-detect để bắt DB mới)
    if [ "$BACKUP_TYPE" = "1" ]; then
        TARGET_DBS=()
        local DB_LIST
        DB_LIST=$(list_dbs 2>/dev/null || true)
        while IFS= read -r db; do
            [ -n "$db" ] && TARGET_DBS+=("$db")
        done <<< "$DB_LIST"
        info "DB phát hiện (${#TARGET_DBS[@]}): ${TARGET_DBS[*]}"
    fi

    BACKUP_START=$(date '+%Y-%m-%d %H:%M:%S')

    for DB in "${TARGET_DBS[@]}"; do
        backup_one "$DB" || true
    done

    BACKUP_END=$(date '+%Y-%m-%d %H:%M:%S')

    # ── Summary terminal ─────────────────────────────────────
    COUNT_OK=0; COUNT_FAIL=0
    echo ""
    echo "  ════════════════════════════════════════════════════"
    echo -e "  ${BOLD}KẾT QUẢ — Cycle #${CYCLE}${NC}"
    echo "  ════════════════════════════════════════════════════"
    echo "  Tổng DB    : ${#TARGET_DBS[@]}"
    echo "  Bắt đầu    : ${BACKUP_START}"
    echo "  Kết thúc   : ${BACKUP_END}"
    echo "  Backup dir : ${BACKUP_DIR}"
    echo ""

    for r in "${RESULTS[@]}"; do
        IFS='|' read -r STATUS DB MSG ROWS_PRE ROWS_POST ROWS_VRF FILE_SIZE FNAME <<< "$r"
        if [ "$STATUS" = "OK" ]; then
            COUNT_OK=$((COUNT_OK + 1))
            ok "  ${DB}"
            info "   File: ${FNAME}  Size: ${FILE_SIZE}"
            info "   Rows: pre=${ROWS_PRE}  post=${ROWS_POST}  restored=${ROWS_VRF}"
        else
            COUNT_FAIL=$((COUNT_FAIL + 1))
            fail "  ${DB}"
            info "   Lỗi: ${MSG}"
            info "   Rows: pre=${ROWS_PRE}  post=${ROWS_POST}  restored=${ROWS_VRF}"
        fi
    done

    echo ""
    echo "  Thành công: ${COUNT_OK} / ${#TARGET_DBS[@]}"
    [ "$COUNT_FAIL" -gt 0 ] && echo "  Thất bại  : ${COUNT_FAIL} / ${#TARGET_DBS[@]}"
    echo "  ════════════════════════════════════════════════════"

    # ── Telegram notify ──────────────────────────────────────
    TELE_DETAIL=""
    for r in "${RESULTS[@]}"; do
        IFS='|' read -r STATUS DB MSG ROWS_PRE ROWS_POST ROWS_VRF FILE_SIZE FNAME <<< "$r"
        if [ "$STATUS" = "OK" ]; then
            TELE_DETAIL+="
✅ <code>${DB}</code>  ${ROWS_VRF} rows  ${FILE_SIZE}
<code>${FNAME}</code>"
        else
            TELE_DETAIL+="
❌ <code>${DB}</code>  ${MSG}
pre=${ROWS_PRE}  post=${ROWS_POST}  restored=${ROWS_VRF}"
        fi
    done

    if [ "$COUNT_FAIL" -eq 0 ]; then
        TELE_ICON="✅"
    else
        TELE_ICON="⚠️"
    fi

    local CYCLE_LABEL=""
    [ "$INTERVAL_SEC" -gt 0 ] && CYCLE_LABEL="  Cycle #${CYCLE} / every $(interval_label "$INTERVAL_RAW")"

    tele_send "${TELE_ICON} <b>BACKUP DB</b>${CYCLE_LABEL}
${TELE_DETAIL}
File backup: <code>${BACKUP_DIR}</code>
Start: ${BACKUP_START}
End: ${BACKUP_END}"

    if [ "$COUNT_FAIL" -eq 0 ]; then
        ok "Cycle #${CYCLE} hoàn tất. Đã notify Telegram."
    else
        warn "Cycle #${CYCLE} có ${COUNT_FAIL} DB lỗi. Đã notify Telegram."
    fi
}

# =========================================
# Helper: password hiển thị *
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
# Telegram: gửi 1 message (cuối)
# =========================================
tele_send() {
    local TEXT="$1"
    if [ -z "$TELE_TOKEN" ] || [ -z "$TELE_CHAT_ID" ] \
       || [ "$TELE_TOKEN" = "your_bot_token_here" ]; then
        warn "Telegram chưa config — bỏ qua notify."
        return 0
    fi

    local EXTRA=""
    [ -n "$TELE_THREAD_ID" ] && EXTRA=", \"message_thread_id\": ${TELE_THREAD_ID}"

    local ESCAPED
    ESCAPED=$(printf '%s' "$TEXT" | python3 -c \
        "import sys,json; print(json.dumps(sys.stdin.read()))" 2>/dev/null \
        || printf '"%s"' "$(printf '%s' "$TEXT" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' ' ')")

    curl -s -X POST \
        "https://api.telegram.org/bot${TELE_TOKEN}/sendMessage" \
        -H "Content-Type: application/json" \
        -d "{\"chat_id\": \"${TELE_CHAT_ID}\", \"text\": ${ESCAPED}, \"parse_mode\": \"HTML\"${EXTRA}}" \
        > /dev/null 2>&1 || warn "Gửi Telegram thất bại (curl lỗi)."
}

# =========================================
# Đếm tổng rows của 1 DB trên source
# (hỗ trợ docker hoặc systemd)
# =========================================
count_rows_src() {
    local TARGET_DB="$1"
    local TBLS total=0

    if [ "$SRC_MODE" = "1" ]; then
        TBLS=$(docker exec "$SRC_CTR" mysql -u"$SRC_USER" -p"$SRC_PASS" -N \
            -e "SHOW TABLES FROM \`${TARGET_DB}\`;" 2>/dev/null | tr '\n' ' ')
        for t in $TBLS; do
            local c
            c=$(docker exec "$SRC_CTR" mysql -u"$SRC_USER" -p"$SRC_PASS" -N \
                -e "SELECT COUNT(*) FROM \`${TARGET_DB}\`.\`${t}\`;" 2>/dev/null \
                | tail -1 | tr -d '[:space:]')
            total=$((total + ${c:-0}))
        done
    else
        TBLS=$(mysql -u"$SRC_USER" -p"$SRC_PASS" -N \
            -e "SHOW TABLES FROM \`${TARGET_DB}\`;" 2>/dev/null | tr '\n' ' ')
        for t in $TBLS; do
            local c
            c=$(mysql -u"$SRC_USER" -p"$SRC_PASS" -N \
                -e "SELECT COUNT(*) FROM \`${TARGET_DB}\`.\`${t}\`;" 2>/dev/null \
                | tail -1 | tr -d '[:space:]')
            total=$((total + ${c:-0}))
        done
    fi
    echo "$total"
}

# =========================================
# Đếm tổng rows trên verify container (luôn docker)
# =========================================
count_rows_vrf() {
    local TARGET_DB="$1"
    local TBLS total=0
    TBLS=$(docker exec "$VRF_CTR" mysql -u"$VRF_USER" -p"$VRF_PASS" -N \
        -e "SHOW TABLES FROM \`${TARGET_DB}\`;" 2>/dev/null | tr '\n' ' ')
    for t in $TBLS; do
        local c
        c=$(docker exec "$VRF_CTR" mysql -u"$VRF_USER" -p"$VRF_PASS" -N \
            -e "SELECT COUNT(*) FROM \`${TARGET_DB}\`.\`${t}\`;" 2>/dev/null \
            | tail -1 | tr -d '[:space:]')
        total=$((total + ${c:-0}))
    done
    echo "$total"
}

# =========================================
# Dump 1 DB từ source
# =========================================
dump_db() {
    local DB="$1" OUT="$2"
    if [ "$SRC_MODE" = "1" ]; then
        docker exec "$SRC_CTR" mysqldump \
            --single-transaction --routines --triggers --opt \
            -u"$SRC_USER" -p"$SRC_PASS" "$DB" 2>/dev/null | gzip > "$OUT"
    else
        mysqldump --single-transaction --routines --triggers --opt \
            -u"$SRC_USER" -p"$SRC_PASS" "$DB" 2>/dev/null | gzip > "$OUT"
    fi
}

# =========================================
# Lấy danh sách DB từ source (bỏ system DB)
# =========================================
list_dbs() {
    local EXCL="'information_schema','performance_schema','mysql','sys'"
    local SQL="SELECT schema_name FROM information_schema.schemata WHERE schema_name NOT IN (${EXCL});"
    if [ "$SRC_MODE" = "1" ]; then
        docker exec "$SRC_CTR" mysql -u"$SRC_USER" -p"$SRC_PASS" -N -e "$SQL" 2>/dev/null
    else
        mysql -u"$SRC_USER" -p"$SRC_PASS" -N -e "$SQL" 2>/dev/null
    fi
}

# =========================================
# Backup + verify 1 DB — trả về 0=OK / 1=FAIL
# Append kết quả vào mảng RESULTS[]
#
# Tại sao dùng pre/post thay vì strict equal:
#   mysqldump --single-transaction chụp snapshot nhất quán tại
#   thời điểm BẮT ĐẦU dump. Trong khi dump đang chạy, source
#   vẫn có thể nhận insert (gen_auto.sh, traffic thật...).
#   → ROWS_VRF (snapshot lúc dump bắt đầu) luôn ≤ ROWS_POST.
#   Verify hợp lệ khi: ROWS_PRE ≤ ROWS_VRF ≤ ROWS_POST.
# =========================================
backup_one() {
    local DB="$1"
    local TS
    TS=$(date '+%Y%m%d_%H%M%S')
    local DUMP_FILE="${BACKUP_DIR}/backup_${DB}_${TS}.sql.gz"
    local VRF_DB="_verify_${TS}"
    local ROWS_PRE=0 ROWS_POST=0 ROWS_VRF=0 FILE_SIZE="—"
    local STATUS="OK" MSG=""

    echo ""
    echo -e "  ${BOLD}━━━ DB: ${DB} ━━━${NC}"

    # ── a. Đếm rows TRƯỚC dump (snapshot pre) ────────────────
    info "Đếm rows nguồn trước dump (pre-snapshot)..."
    ROWS_PRE=$(count_rows_src "$DB")
    info "Rows pre-dump : ${ROWS_PRE}"

    # ── b. Dump ───────────────────────────────────────────────
    info "Đang dump (--single-transaction)..."
    if ! dump_db "$DB" "$DUMP_FILE"; then
        STATUS="FAIL"; MSG="Dump thất bại."
        fail "$MSG"
        RESULTS+=("FAIL|${DB}|${MSG}|${ROWS_PRE}|—|—|—|—")
        return 1
    fi
    FILE_SIZE=$(du -sh "$DUMP_FILE" | cut -f1)
    md5sum "$DUMP_FILE" > "${DUMP_FILE}.md5"
    ok "Dump OK — ${FILE_SIZE}  →  $(basename "$DUMP_FILE")"

    # ── c. Đếm rows NGAY SAU dump (snapshot post) ────────────
    #   Dump dùng --single-transaction nên snapshot nằm trong
    #   khoảng [pre, post]. ROWS_VRF hợp lệ nếu nằm trong range này.
    info "Đếm rows nguồn sau dump (post-snapshot)..."
    ROWS_POST=$(count_rows_src "$DB")
    info "Rows post-dump: ${ROWS_POST}"

    # ── d. MD5 ───────────────────────────────────────────────
    info "Kiểm tra MD5..."
    if ! md5sum -c "${DUMP_FILE}.md5" --quiet 2>/dev/null; then
        STATUS="FAIL"; MSG="MD5 không khớp — file dump bị lỗi."
        fail "$MSG"
        RESULTS+=("FAIL|${DB}|${MSG}|${ROWS_PRE}|${ROWS_POST}|—|${FILE_SIZE}|$(basename "$DUMP_FILE")")
        return 1
    fi
    ok "MD5 OK"

    # ── e. Restore thử trên verify container ─────────────────
    info "Tạo DB tạm '${VRF_DB}' trên verify container '${VRF_CTR}'..."
    if ! docker exec "$VRF_CTR" mysql -u"$VRF_USER" -p"$VRF_PASS" \
            -e "CREATE DATABASE \`${VRF_DB}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" \
            2>/dev/null; then
        STATUS="FAIL"; MSG="Không tạo được DB tạm '${VRF_DB}' trên verify container."
        fail "$MSG"
        RESULTS+=("FAIL|${DB}|${MSG}|${ROWS_PRE}|${ROWS_POST}|—|${FILE_SIZE}|$(basename "$DUMP_FILE")")
        return 1
    fi

    info "Đang restore thử..."
    if ! gunzip -c "$DUMP_FILE" \
            | docker exec -i "$VRF_CTR" mysql -u"$VRF_USER" -p"$VRF_PASS" "$VRF_DB" 2>/dev/null; then
        STATUS="FAIL"; MSG="Restore thử thất bại — dump có thể bị hỏng."
        fail "$MSG"
        docker exec "$VRF_CTR" mysql -u"$VRF_USER" -p"$VRF_PASS" \
            -e "DROP DATABASE IF EXISTS \`${VRF_DB}\`;" 2>/dev/null || true
        RESULTS+=("FAIL|${DB}|${MSG}|${ROWS_PRE}|${ROWS_POST}|—|${FILE_SIZE}|$(basename "$DUMP_FILE")")
        return 1
    fi
    ok "Restore thử OK"

    # ── f. Verify row count (range check) ────────────────────
    info "Đang đếm rows trên verify container..."
    ROWS_VRF=$(count_rows_vrf "$VRF_DB")

    echo ""
    info "  ┌─ Row count summary ─────────────────────────────"
    info "  │  Source pre-dump  : ${ROWS_PRE}"
    info "  │  Source post-dump : ${ROWS_POST}  (source vẫn nhận insert trong lúc dump)"
    info "  │  Restored         : ${ROWS_VRF}  (snapshot nhất quán của dump)"
    info "  │  Valid range      : ${ROWS_PRE} ≤ restored ≤ ${ROWS_POST}"
    info "  └─────────────────────────────────────────────────"

    # Drop DB tạm dù kết quả thế nào
    docker exec "$VRF_CTR" mysql -u"$VRF_USER" -p"$VRF_PASS" \
        -e "DROP DATABASE IF EXISTS \`${VRF_DB}\`;" 2>/dev/null || true
    info "Đã drop DB tạm '${VRF_DB}'."

    # Kiểm tra ROWS_VRF nằm trong [ROWS_PRE, ROWS_POST]
    if [ "${ROWS_VRF}" -lt "${ROWS_PRE}" ] || [ "${ROWS_VRF}" -gt "${ROWS_POST}" ]; then
        STATUS="FAIL"
        MSG="Row count ngoài range hợp lệ (pre:${ROWS_PRE} ≤ restored:${ROWS_VRF} ≤ post:${ROWS_POST})."
        fail "$MSG"
        RESULTS+=("FAIL|${DB}|${MSG}|${ROWS_PRE}|${ROWS_POST}|${ROWS_VRF}|${FILE_SIZE}|$(basename "$DUMP_FILE")")
        return 1
    fi

    ok "Verify OK — restored=${ROWS_VRF} nằm trong range [${ROWS_PRE}, ${ROWS_POST}]."
    RESULTS+=("OK|${DB}||${ROWS_PRE}|${ROWS_POST}|${ROWS_VRF}|${FILE_SIZE}|$(basename "$DUMP_FILE")")
    return 0
}

# =========================================
# MAIN
# =========================================
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}  CRON BACKUP — MariaDB / MySQL${NC}"
echo    "  Dump → verify restore (container riêng) → notify Telegram"
echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
echo ""

# ── Chọn loại backup ─────────────────────────────────────────
echo "  Chọn loại backup:"
echo "    1) Full — tất cả DB trên instance"
echo "    2) Một DB cụ thể"
echo ""
read -p "  Chọn [1/2]: " BACKUP_TYPE
echo ""

# ── Source: docker hay systemd? ──────────────────────────────
echo "── Source DB ──"
echo "  DB chạy dạng gì?"
echo "    1) Docker container"
echo "    2) Service (systemd / local)"
echo ""
read -p "  Chọn [1/2]: " input; SRC_MODE=${input:-1}

SRC_CTR=""
if [ "$SRC_MODE" = "1" ]; then
    read -p "  Tên container (mariadb-104): " input; SRC_CTR=${input:-mariadb-104}
fi
read -p "  DB User (root)             : " input; SRC_USER=${input:-root}
read_pass "  DB Password                : " SRC_PASS

# ── Tên DB (nếu chọn 1 DB) ───────────────────────────────────
TARGET_DB_SINGLE=""
if [ "$BACKUP_TYPE" = "2" ]; then
    read -p "  Tên DB cần backup          : " TARGET_DB_SINGLE
fi

# ── Verify container ─────────────────────────────────────────
echo ""
echo "── Verify container (tự tạo nếu chưa có — luôn dùng Docker) ──"
read -p "  Tên container              : " VRF_CTR

# ── Thư mục lưu backup ───────────────────────────────────────
echo ""
echo "── Lưu file backup ──"
read -p "  Thư mục backup (/tmp/backup): " input; BACKUP_DIR=${input:-/tmp/backup}

# ── Tần suất chạy ────────────────────────────────────────────
echo ""
echo "── Tần suất backup ──"
echo "  Định dạng : <số><đơn vị>"
echo "  Đơn vị    : m=phút  h=giờ  d=ngày  w=tuần  y=năm"
echo "  Ví dụ     : 30m  6h  1d  7d  2w  1y"
echo "  Để trống  : chỉ chạy 1 lần"
echo ""
read -p "  Tần suất (Enter = 1 lần): " INTERVAL_RAW

INTERVAL_SEC=0
if [ -n "$INTERVAL_RAW" ]; then
    INTERVAL_SEC=$(parse_interval "$INTERVAL_RAW") || {
        warn "Không hiểu định dạng '${INTERVAL_RAW}' — sẽ chạy 1 lần."
        INTERVAL_RAW=""
        INTERVAL_SEC=0
    }
    [ "$INTERVAL_SEC" -le 0 ] && {
        warn "Tần suất không hợp lệ — sẽ chạy 1 lần."
        INTERVAL_RAW=""
        INTERVAL_SEC=0
    }
fi

# ── Preview + xác nhận ───────────────────────────────────────
echo ""
echo "  ════════════════════════════════════════════════════"
echo "  Backup type : $([ "$BACKUP_TYPE" = "1" ] && echo "Full (tất cả DB)" || echo "Một DB: ${TARGET_DB_SINGLE}")"
if [ "$SRC_MODE" = "1" ]; then
    echo "  Source      : Docker container '${SRC_CTR}'"
else
    echo "  Source      : Service (systemd/local)"
fi
echo "  DB User     : ${SRC_USER}"
echo "  Verify CTR  : Docker container '${VRF_CTR}'"
echo "  Backup dir  : ${BACKUP_DIR}"
if [ "$INTERVAL_SEC" -gt 0 ]; then
    echo "  Tần suất    : mỗi $(interval_label "$INTERVAL_RAW")  (${INTERVAL_RAW})"
else
    echo "  Tần suất    : 1 lần"
fi
if [ -n "$TELE_THREAD_ID" ]; then
    echo "  Telegram    : chat=${TELE_CHAT_ID}  thread=${TELE_THREAD_ID}"
else
    echo "  Telegram    : chat=${TELE_CHAT_ID}  (no thread)"
fi
echo "  ════════════════════════════════════════════════════"
echo ""
read -p "  Tiếp tục? (yes/no): " confirm
[[ "$confirm" == "yes" ]] || { echo "  Hủy."; exit 0; }

mkdir -p "$BACKUP_DIR" || { fail "Không tạo được thư mục: ${BACKUP_DIR}"; exit 1; }

# =========================================
# [0] Kiểm tra kết nối source + verify
# =========================================
step "[0] Kiểm tra kết nối..."

if [ "$SRC_MODE" = "1" ]; then
    docker inspect "$SRC_CTR" &>/dev/null \
        || { fail "Container source '${SRC_CTR}' không tồn tại."; exit 1; }
    [ "$(docker inspect -f '{{.State.Running}}' "$SRC_CTR" 2>/dev/null)" = "true" ] \
        || { fail "Container source '${SRC_CTR}' không đang chạy."; exit 1; }
    docker exec "$SRC_CTR" mysql -u"$SRC_USER" -p"$SRC_PASS" -N \
        -e "SELECT 1;" > /dev/null 2>&1 \
        || { fail "Không kết nối được DB trên source container."; exit 1; }
    ok "Source container '${SRC_CTR}' OK"
else
    mysql -u"$SRC_USER" -p"$SRC_PASS" -N -e "SELECT 1;" > /dev/null 2>&1 \
        || { fail "Không kết nối được DB trên source (systemd)."; exit 1; }
    ok "Source service OK"
fi

docker inspect "$VRF_CTR" &>/dev/null && \
[ "$(docker inspect -f '{{.State.Running}}' "$VRF_CTR" 2>/dev/null)" = "true" ] && \
docker exec "$VRF_CTR" mysql -u"$VRF_USER" -p"$VRF_PASS" -N \
    -e "SELECT 1;" > /dev/null 2>&1
VRF_LIVE=$?

if [ "$VRF_LIVE" -eq 0 ]; then
    ok "Verify container '${VRF_CTR}' đang chạy — dùng luôn."
else
    warn "Verify container '${VRF_CTR}' chưa tồn tại / chưa chạy — tự tạo..."
    # Nếu container tồn tại nhưng stopped → xóa trước
    docker rm -f "$VRF_CTR" > /dev/null 2>&1 || true
    setup_verify_container "$VRF_CTR"
fi

# Kiểm tra curl
command -v curl &>/dev/null || warn "curl không có — Telegram notify sẽ không hoạt động."

# ── Lấy danh sách DB cần backup ──────────────────────────────
declare -a TARGET_DBS=()

if [ "$BACKUP_TYPE" = "1" ]; then
    step "[1] Lấy danh sách DB từ source..."
    DB_LIST=$(list_dbs)
    if [ -z "$DB_LIST" ]; then
        fail "Không lấy được danh sách DB."; exit 1
    fi
    while IFS= read -r db; do
        [ -n "$db" ] && TARGET_DBS+=("$db")
    done <<< "$DB_LIST"
    echo "  DB tìm thấy (${#TARGET_DBS[@]}):"
    for db in "${TARGET_DBS[@]}"; do info "$db"; done
else
    TARGET_DBS=("$TARGET_DB_SINGLE")
fi

# =========================================
# Scheduler loop
# =========================================
CYCLE=0

if [ "$INTERVAL_SEC" -gt 0 ]; then
    echo ""
    ok "Chế độ lặp: mỗi $(interval_label "$INTERVAL_RAW"). Nhấn Ctrl+C để dừng."
fi

while true; do
    CYCLE=$((CYCLE + 1))
    run_backup_cycle "$CYCLE"

    # Chế độ 1 lần → thoát sau cycle đầu
    [ "$INTERVAL_SEC" -le 0 ] && break

    # Tính thời điểm chạy tiếp
    NEXT_TS=$(date -d "+${INTERVAL_SEC} seconds" '+%Y-%m-%d %H:%M:%S' 2>/dev/null \
        || date -v "+${INTERVAL_SEC}S" '+%Y-%m-%d %H:%M:%S' 2>/dev/null \
        || echo "N/A")

    echo ""
    info "Lần chạy tiếp theo: ${NEXT_TS}  (sau $(interval_label "$INTERVAL_RAW"))"
    info "Nhấn Ctrl+C để dừng."

    sleep "$INTERVAL_SEC"
done
