#!/bin/bash
set -euo pipefail

# ============================================================
#  ROLLBACK DB TARGET
#
#  Mục đích: Khôi phục DB trên máy TARGET về trạng thái
#            trước khi migrate (dùng file backup đã tạo ở bước migrate)
# ============================================================

# =========================================
# Helper: nhập password hiển thị *
# =========================================
read_pass() {
    local prompt="$1" varname="$2" pass="" char=""
    printf "%s" "$prompt"
    while IFS= read -r -s -n1 char; do
        if [[ -z "$char" ]]; then
            break
        elif [[ "$char" == $'\x7f' || "$char" == $'\b' ]]; then
            if [ ${#pass} -gt 0 ]; then pass="${pass%?}"; printf "\b \b"; fi
        else
            pass="${pass}${char}"; printf "*"
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
echo "  ROLLBACK DB TARGET"
echo "  Khôi phục DB về trạng thái trước khi migrate"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

echo "── TARGET (máy cần rollback) ──"
read -p "  Host IP          : " input; TGT_HOST=${input}
read -p "  SSH User (root)  : " input; TGT_SSH_USER=${input:-root}
read -p "  SSH Port (22)    : " input; TGT_SSH_PORT=${input:-22}
echo   "  DB chạy dạng gì?   1) Docker container   2) Service (systemd)"
read -p "  Chọn [1/2]       : " input; TGT_DB_MODE=${input:-1}
if [ "$TGT_DB_MODE" = "1" ]; then
    read -p "  Tên container    : " input; TGT_CONTAINER=${input}
else
    TGT_CONTAINER=""
fi
read -p "  Tên DB           : " TGT_DB_NAME
read -p "  DB User (root)   : " input; TGT_DB_USER=${input:-root}
read_pass "  DB Password      : " TGT_DB_PASS
read -p "  Thư mục chứa backup (/tmp/migrate): " input; TGT_DIR=${input:-/tmp/migrate}

# =========================================
# Build commands
# =========================================
SSH_TGT="ssh -p ${TGT_SSH_PORT} ${TGT_SSH_USER}@${TGT_HOST}"

if [ "$TGT_DB_MODE" = "1" ]; then
    TGT_EXEC="docker exec ${TGT_CONTAINER} mysql --user=${TGT_DB_USER} --password=${TGT_DB_PASS} -N"
    TGT_IMPORT="docker exec -i ${TGT_CONTAINER} mysql --user=${TGT_DB_USER} --password=${TGT_DB_PASS} ${TGT_DB_NAME}"
else
    TGT_EXEC="mysql --user=${TGT_DB_USER} --password=${TGT_DB_PASS} -N"
    TGT_IMPORT="mysql --user=${TGT_DB_USER} --password=${TGT_DB_PASS} ${TGT_DB_NAME}"
fi

# =========================================
# Kiểm tra SSH + DB
# =========================================
echo ""
echo "Kiểm tra kết nối..."
$SSH_TGT "echo 'SSH TARGET: OK'" \
    || { echo "❌ Không SSH được vào TARGET (${TGT_HOST})"; exit 1; }
$SSH_TGT "${TGT_EXEC} -e 'SELECT 1;' > /dev/null" && echo "DB TARGET: OK" \
    || { echo "❌ Không kết nối được DB trên TARGET — kiểm tra user/pass/container"; exit 1; }

# =========================================
# Tìm file backup
# =========================================
echo ""
echo "Tìm file backup trong ${TGT_DIR}..."
BACKUP_FILE=$(ssh -p ${TGT_SSH_PORT} ${TGT_SSH_USER}@${TGT_HOST} \
    "ls -t ${TGT_DIR}/backup_${TGT_DB_NAME}_*.sql.gz 2>/dev/null | head -1" || true)

if [ -z "$BACKUP_FILE" ]; then
    echo "❌ Không tìm thấy file backup trong ${TGT_DIR}"
    echo "   Tìm pattern: backup_${TGT_DB_NAME}_*.sql.gz"
    exit 1
fi

# Lấy thời gian tạo file backup để hiển thị
BACKUP_TIME=$(echo "$BACKUP_FILE" | grep -oP '\d{8}_\d{6}' || echo "unknown")

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  File backup tìm thấy:"
echo "  ${BACKUP_FILE}"
echo "  Thời điểm backup: ${BACKUP_TIME}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  ⚠️  DB hiện tại trên TARGET (${TGT_DB_NAME}) sẽ bị XÓA"
echo "     và thay bằng nội dung từ file backup trên."
echo ""
read -p "  Tiếp tục rollback? (yes/no): " confirm
[[ "$confirm" == "yes" ]] || { echo "Hủy."; exit 0; }

# =========================================
# Rollback
# =========================================
echo ""
echo "Đang rollback..."
$SSH_TGT "${TGT_EXEC} -e 'DROP DATABASE IF EXISTS \`${TGT_DB_NAME}\`; CREATE DATABASE \`${TGT_DB_NAME}\`;'"
$SSH_TGT "gunzip -c ${BACKUP_FILE} | ${TGT_IMPORT}" && echo "Rollback OK" || {
    echo "❌ Rollback FAIL — kiểm tra thủ công trên TARGET."
    exit 1
}

# =========================================
# Xóa file backup?
# =========================================
echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "  ✅ HOÀN TẤT"
echo "  DB TARGET đã về trạng thái trước khi migrate."
echo "╚══════════════════════════════════════════════════════╝"
echo ""
read -p "  Xóa file backup sau khi rollback xong? (yes/no): " del_confirm
if [[ "$del_confirm" == "yes" ]]; then
    $SSH_TGT "rm -f ${BACKUP_FILE} ${BACKUP_FILE}.md5"
    echo "→ Đã xóa: ${BACKUP_FILE}"
else
    echo "→ Giữ lại backup tại: ${BACKUP_FILE}"
fi
echo ""
