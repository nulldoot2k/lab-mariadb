#!/bin/bash
set -euo pipefail

# ============================================================
#  RESTORE DB: STANDBY → PRIMARY
#
#  Bối cảnh:
#    PRIMARY  = DB gốc, bị lỗi, nay đã sống lại
#               → cần nhận data mới nhất từ STANDBY
#    STANDBY  = DB tạm thời, client đang dùng khi PRIMARY lỗi
#               → có data mới nhất, lấy data từ đây
#
#  Luồng:
#    1. Backup DB hiện tại trên PRIMARY (phòng rollback)
#    2. Dump DB từ STANDBY
#    3. Transfer file dump STANDBY → PRIMARY (rsync trực tiếp)
#    4. Kiểm tra integrity (MD5 + size)
#    5. Restore vào PRIMARY
#    6. Verify row count (so sánh với snapshot lúc dump)
# ============================================================

# =========================================
# Helper: nhập password hiển thị *
# =========================================
read_pass() {
    local prompt="$1"
    local varname="$2"
    local pass="" char=""
    printf "%s" "$prompt"
    while IFS= read -r -s -n1 char; do
        if [[ -z "$char" ]]; then
            break
        elif [[ "$char" == $'\x7f' || "$char" == $'\b' ]]; then
            if [ ${#pass} -gt 0 ]; then
                pass="${pass%?}"
                printf "\b \b"
            fi
        else
            pass="${pass}${char}"
            printf "*"
        fi
    done
    echo ""
    eval "$varname=\"$pass\""
}

# =========================================
# Nhập thông tin
# =========================================
echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "  RESTORE DB: PRIMARY → STANDBY"
echo ""
echo "  STANDBY = DB backup, DB tạm thời sử dụng"
echo "  PRIMARY = DB origin, DB mục tiêu cần restore"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

echo "── STANDBY ──"
read -p "  Host IP          : " input; STBY_HOST=${input}
read -p "  SSH User (root)  : " input; STBY_SSH_USER=${input:-root}
read -p "  SSH Port (22)    : " input; STBY_SSH_PORT=${input:-22}
echo   "  DB chạy dạng gì?   1) Docker container   2) Service (systemd)"
read -p "  Chọn [1/2]       : " input; STBY_DB_MODE=${input:-1}
if [ "$STBY_DB_MODE" = "1" ]; then
    read -p "  Tên container    : " input; STBY_CONTAINER=${input}
else
    STBY_CONTAINER=""
fi
read -p "  Tên DB           : " STBY_DB_NAME
read -p "  DB User (root)   : " input; STBY_DB_USER=${input:-root}
read_pass "  DB Password      : " STBY_DB_PASS
read -p "  Thư mục làm việc (/tmp/migrate): " input; STBY_DIR=${input:-/tmp/migrate}

echo ""
echo "── PRIMARY ──"
read -p "  Host IP          : " input; PRI_HOST=${input}
read -p "  SSH User (root)  : " input; PRI_SSH_USER=${input:-root}
read -p "  SSH Port (22)    : " input; PRI_SSH_PORT=${input:-22}
echo   "  DB chạy dạng gì?   1) Docker container   2) Service (systemd)"
read -p "  Chọn [1/2]       : " input; PRI_DB_MODE=${input:-1}
if [ "$PRI_DB_MODE" = "1" ]; then
    read -p "  Tên container    : " input; PRI_CONTAINER=${input}
else
    PRI_CONTAINER=""
fi
read -p "  Tên DB           : " PRI_DB_NAME
read -p "  DB User (root)   : " input; PRI_DB_USER=${input:-root}
read_pass "  DB Password      : " PRI_DB_PASS
read -p "  Thư mục làm việc (/tmp/migrate): " input; PRI_DIR=${input:-/tmp/migrate}

echo ""
echo "── Verify ──"
echo "  Nhập tên bảng cần verify COUNT(*), cách nhau bằng dấu cách."
echo "  Để trống → tự động đếm toàn bộ bảng trong DB."
read -p "  Tables (Enter = all): " TABLES_INPUT

# =========================================
# Confirm
# =========================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Xác nhận thông tin"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  STANDBY : ${STBY_SSH_USER}@${STBY_HOST}:${STBY_SSH_PORT}"
echo "            DB=${STBY_DB_NAME} | $( [[ "$STBY_DB_MODE" == "1" ]] && echo "docker (${STBY_CONTAINER})" || echo "service" )"
echo ""
echo "  PRIMARY : ${PRI_SSH_USER}@${PRI_HOST}:${PRI_SSH_PORT}"
echo "            DB=${PRI_DB_NAME} | $( [[ "$PRI_DB_MODE" == "1" ]] && echo "docker (${PRI_CONTAINER})" || echo "service" )"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  ⚠️  DB hiện tại trên PRIMARY (${PRI_DB_NAME}) sẽ bị XÓA"
echo "     và thay bằng data mới nhất từ STANDBY."
echo "     Backup tự động tạo trước khi xóa để phòng rollback."
echo ""
read -p "  Tiếp tục? (yes/no): " confirm
[[ "$confirm" == "yes" ]] || { echo "Hủy."; exit 0; }

# =========================================
# Helper: build mysql/mysqldump command
# =========================================
_cmd() {
    local mode=$1 ctr=$2 user=$3 pass=$4 db=$5 action=$6
    if [ "$mode" = "1" ]; then
        case $action in
            exec)   echo "docker exec ${ctr} mysql --user=${user} --password=${pass} -N" ;;
            dump)   echo "docker exec ${ctr} mysqldump --single-transaction --routines --triggers --opt --user=${user} --password=${pass} ${db}" ;;
            import) echo "docker exec -i ${ctr} mysql --user=${user} --password=${pass} ${db}" ;;
        esac
    else
        case $action in
            exec)   echo "mysql --user=${user} --password=${pass} -N" ;;
            dump)   echo "mysqldump --single-transaction --routines --triggers --opt --user=${user} --password=${pass} ${db}" ;;
            import) echo "mysql --user=${user} --password=${pass} ${db}" ;;
        esac
    fi
}

SSH_STBY="ssh -p ${STBY_SSH_PORT} ${STBY_SSH_USER}@${STBY_HOST}"
SSH_PRI="ssh -p ${PRI_SSH_PORT} ${PRI_SSH_USER}@${PRI_HOST}"

DUMP_ON_STBY="${STBY_DIR}/dump_${STBY_DB_NAME}.sql.gz"
DUMP_ON_PRI="${PRI_DIR}/dump_${STBY_DB_NAME}.sql.gz"

STBY_EXEC=$(_cmd "$STBY_DB_MODE" "$STBY_CONTAINER" "$STBY_DB_USER" "$STBY_DB_PASS" "$STBY_DB_NAME" exec)
STBY_DUMP=$(_cmd "$STBY_DB_MODE" "$STBY_CONTAINER" "$STBY_DB_USER" "$STBY_DB_PASS" "$STBY_DB_NAME" dump)
PRI_EXEC=$(_cmd "$PRI_DB_MODE" "$PRI_CONTAINER" "$PRI_DB_USER" "$PRI_DB_PASS" "$PRI_DB_NAME" exec)
PRI_DUMP=$(_cmd "$PRI_DB_MODE" "$PRI_CONTAINER" "$PRI_DB_USER" "$PRI_DB_PASS" "$PRI_DB_NAME" dump)
PRI_IMPORT=$(_cmd "$PRI_DB_MODE" "$PRI_CONTAINER" "$PRI_DB_USER" "$PRI_DB_PASS" "$PRI_DB_NAME" import)

$SSH_STBY "mkdir -p ${STBY_DIR}"
$SSH_PRI  "mkdir -p ${PRI_DIR}"

# =========================================
# Helper: đếm row count
# =========================================
count_rows() {
    local SSH_PORT=$1 SSH_USER=$2 SSH_HOST=$3
    local DB_MODE=$4 CONTAINER=$5 DB_USER=$6 DB_PASS=$7 DB_NAME=$8
    local TABLES=$9

    ssh -p ${SSH_PORT} ${SSH_USER}@${SSH_HOST} bash << ENDSSH
DB_MODE="${DB_MODE}"
CONTAINER="${CONTAINER}"
DB_USER="${DB_USER}"
DB_PASS="${DB_PASS}"
DB_NAME="${DB_NAME}"
TABLES_INPUT="${TABLES}"

if [ "\$DB_MODE" = "1" ]; then
    MYSQL="docker exec \${CONTAINER} mysql -u\${DB_USER} -p\${DB_PASS} -N"
else
    MYSQL="mysql -u\${DB_USER} -p\${DB_PASS} -N"
fi

if [ -n "\$TABLES_INPUT" ]; then
    tbls=\$TABLES_INPUT
else
    tbls=\$(\$MYSQL -e "SHOW TABLES FROM \\\`\${DB_NAME}\\\`;" 2>/dev/null)
fi

total=0
for t in \$tbls; do
    c=\$(\$MYSQL -e "SELECT COUNT(*) FROM \\\`\${DB_NAME}\\\`.\\\`\${t}\\\`;" 2>/dev/null | tail -1 | tr -d '[:space:]')
    total=\$((total + c))
done
echo \$total
ENDSSH
}

# =========================================
# [0/6] Kiểm tra kết nối SSH + DB
# =========================================
echo ""
echo "[0/6] Kiểm tra kết nối SSH và DB..."

$SSH_STBY "echo 'SSH STANDBY: OK'" || { echo "❌ Không SSH được vào STANDBY (${STBY_HOST})"; exit 1; }
$SSH_PRI  "echo 'SSH PRIMARY: OK'" || { echo "❌ Không SSH được vào PRIMARY (${PRI_HOST})";  exit 1; }

$SSH_STBY "${STBY_EXEC} -e 'SELECT 1;' > /dev/null" && echo "DB STANDBY: OK" \
    || { echo "❌ Không kết nối được DB trên STANDBY — kiểm tra user/pass/container"; exit 1; }
$SSH_PRI  "${PRI_EXEC}  -e 'SELECT 1;' > /dev/null" && echo "DB PRIMARY: OK" \
    || { echo "❌ Không kết nối được DB trên PRIMARY — kiểm tra user/pass/container"; exit 1; }

# =========================================
# [1/6] Backup DB hiện tại trên PRIMARY
# =========================================
echo ""
echo "[1/6] Backup DB hiện tại trên PRIMARY (phòng rollback)..."
BACKUP_FILE="${PRI_DIR}/backup_${PRI_DB_NAME}_$(date +%Y%m%d_%H%M%S).sql.gz"
$SSH_PRI "${PRI_DUMP} | gzip > ${BACKUP_FILE} && md5sum ${BACKUP_FILE} > ${BACKUP_FILE}.md5 && echo 'Backup OK: ${BACKUP_FILE}'"

# =========================================
# [2/6] Dump DB từ STANDBY
# =========================================
echo ""
echo "[2/6] Dump DB từ STANDBY..."
$SSH_STBY "${STBY_DUMP} | gzip > ${DUMP_ON_STBY} && md5sum ${DUMP_ON_STBY} > ${DUMP_ON_STBY}.md5 && du -b ${DUMP_ON_STBY} | cut -f1 > ${DUMP_ON_STBY}.size && echo 'Dump OK'"

echo "→ Đếm rows trên STANDBY tại thời điểm dump (snapshot để verify sau)..."
ROW_COUNT_STBY=$(count_rows \
    "$STBY_SSH_PORT" "$STBY_SSH_USER" "$STBY_HOST" \
    "$STBY_DB_MODE" "$STBY_CONTAINER" "$STBY_DB_USER" "$STBY_DB_PASS" "$STBY_DB_NAME" \
    "$TABLES_INPUT")
echo "→ Rows STANDBY lúc dump: ${ROW_COUNT_STBY}"

# =========================================
# [3/6] Transfer STANDBY → PRIMARY (rsync trực tiếp)
# =========================================
echo ""
echo "[3/6] Transfer dump STANDBY → PRIMARY..."
echo "   (Yêu cầu SSH key từ STANDBY sang PRIMARY đã được cấu hình)"

$SSH_STBY "ssh -p ${PRI_SSH_PORT} -o BatchMode=yes -o ConnectTimeout=5 ${PRI_SSH_USER}@${PRI_HOST} exit" \
    || { echo "❌ STANDBY không có SSH key sang PRIMARY — cần cấu hình SSH key trước."; exit 1; }

$SSH_STBY "rsync -az --progress --partial \
    -e 'ssh -p ${PRI_SSH_PORT}' \
    ${DUMP_ON_STBY} ${DUMP_ON_STBY}.md5 ${DUMP_ON_STBY}.size \
    ${PRI_SSH_USER}@${PRI_HOST}:${PRI_DIR}/"

$SSH_STBY "rm -f ${DUMP_ON_STBY} ${DUMP_ON_STBY}.md5 ${DUMP_ON_STBY}.size"
echo "Transfer OK — đã xóa file tạm trên STANDBY."

# =========================================
# [4/6] Kiểm tra integrity trên PRIMARY
# =========================================
echo ""
echo "[4/6] Kiểm tra integrity file dump trên PRIMARY..."
$SSH_PRI "
    md5sum -c ${DUMP_ON_PRI}.md5 || { echo 'MD5 FAIL'; exit 1; }
    [ \"\$(du -b ${DUMP_ON_PRI} | cut -f1)\" -eq \"\$(cat ${DUMP_ON_PRI}.size)\" ] || { echo 'Size FAIL'; exit 1; }
    echo 'Integrity OK'
" || { echo "❌ File dump bị lỗi — dừng, không restore."; exit 1; }

# =========================================
# [5/6] Restore vào PRIMARY
# =========================================
echo ""
echo "[5/6] Restore vào PRIMARY (DROP & recreate DB '${PRI_DB_NAME}')..."
$SSH_PRI "${PRI_EXEC} -e 'DROP DATABASE IF EXISTS \`${PRI_DB_NAME}\`; CREATE DATABASE \`${PRI_DB_NAME}\`;'"
$SSH_PRI "gunzip -c ${DUMP_ON_PRI} | ${PRI_IMPORT}" && echo "Restore OK" || {
    echo "❌ Restore FAIL."
    echo "   Backup còn tại PRIMARY: ${BACKUP_FILE}"
    echo "   Chạy rollback_db.sh để khôi phục."
    exit 1
}

# =========================================
# [6/6] Verify
# =========================================
echo ""
echo "[6/6] Verify row count (so với snapshot lúc dump STANDBY)..."

ROW_COUNT_PRI=$(count_rows \
    "$PRI_SSH_PORT" "$PRI_SSH_USER" "$PRI_HOST" \
    "$PRI_DB_MODE" "$PRI_CONTAINER" "$PRI_DB_USER" "$PRI_DB_PASS" "$PRI_DB_NAME" \
    "$TABLES_INPUT")

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Rows STANDBY (lúc dump)    : ${ROW_COUNT_STBY}"
echo "  Rows PRIMARY (sau restore) : ${ROW_COUNT_PRI}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ "${ROW_COUNT_PRI}" != "${ROW_COUNT_STBY}" ]; then
    echo "❌ VERIFY FAIL: Rows không khớp!"
    echo "   Backup còn tại PRIMARY: ${BACKUP_FILE}"
    echo "   Chạy rollback_db.sh để khôi phục."
    exit 1
fi

echo "✅ VERIFY OK: Rows khớp (${ROW_COUNT_PRI})"

$SSH_PRI "rm -f ${DUMP_ON_PRI} ${DUMP_ON_PRI}.md5 ${DUMP_ON_PRI}.size"
echo "→ Đã xóa file dump tạm trên PRIMARY."

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "  ✅ HOÀN TẤT"
echo "  Backup cũ còn tại PRIMARY : ${BACKUP_FILE}"
echo "  Xóa thủ công khi không cần rollback nữa."
echo "╚══════════════════════════════════════════════════════╝"
echo ""
