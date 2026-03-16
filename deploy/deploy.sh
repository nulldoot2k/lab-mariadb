#!/bin/bash
set -euo pipefail

# ============================================================
#  DEPLOY / DELETE MARIADB VIA DOCKER-COMPOSE
# ============================================================

# =========================================
# Config
# =========================================
BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LOCAL_DIR="${BASE_DIR}"
REMOTE_DIR="/root/mariadb"
COMPOSE_FILE="compose/docker-compose.yml"

# =========================================
# Colors
# =========================================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()   { echo -e "    ${GREEN}✅ $1${NC}"; }
fail() { echo -e "    ${RED}❌ $1${NC}"; }
info() { echo -e "    ${CYAN}   $1${NC}"; }
warn() { echo -e "    ${YELLOW}⚠️  $1${NC}"; }
step() { echo -e "\n${CYAN}$1${NC}"; echo "  ────────────────────────────────────────────────────"; }

run_parallel() {
    for pid in "${@}"; do wait "$pid" 2>/dev/null || true; done
}

# =========================================
# Function: nhập danh sách server
# =========================================
input_servers() {
    echo ""
    read -p "  Số lượng server: " SERVER_COUNT
    echo ""
    SERVERS=(); SSH_PORTS=(); SSH_USERS=()
    for i in $(seq 1 $SERVER_COUNT); do
        echo "  ── Server #${i} ──"
        read -p "    Host IP / domain : " host
        read -p "    SSH User (root)  : " input; user=${input:-root}
        read -p "    SSH Port (22)    : " input; port=${input:-22}
        SERVERS+=("$host"); SSH_USERS+=("$user"); SSH_PORTS+=("$port")
        echo ""
    done
}

# =========================================
# Function: kiểm tra SSH song song
# =========================================
check_ssh() {
    step "[1] Kiểm tra kết nối SSH..."
    echo "  Đang kiểm tra ${SERVER_COUNT} server cùng lúc..."
    local tmp=$(mktemp -d); local pids=()
    for i in $(seq 0 $((SERVER_COUNT - 1))); do
        local host=${SERVERS[$i]} user=${SSH_USERS[$i]} port=${SSH_PORTS[$i]}
        ( ssh -p "$port" -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no \
            "${user}@${host}" "echo ok" &>/dev/null \
            && echo "ok" > "${tmp}/r_${i}" || echo "fail" > "${tmp}/r_${i}" ) &
        pids+=($!)
    done
    run_parallel "${pids[@]}"
    echo ""
    local all_ok=true
    for i in $(seq 0 $((SERVER_COUNT - 1))); do
        local host=${SERVERS[$i]} user=${SSH_USERS[$i]} port=${SSH_PORTS[$i]}
        local r=$(cat "${tmp}/r_${i}" 2>/dev/null || echo "fail")
        [ "$r" = "ok" ] && ok "${user}@${host}:${port}" || { fail "${user}@${host}:${port} — không kết nối được"; all_ok=false; }
    done
    rm -rf "$tmp"
    [ "$all_ok" = true ] || { echo ""; fail "Một số server không SSH được. Dừng lại."; return 1; }
}

# =========================================
# Function: kiểm tra Docker song song
# =========================================
check_docker() {
    step "[2] Kiểm tra Docker & Docker Compose..."
    echo "  Đang kiểm tra ${SERVER_COUNT} server cùng lúc..."
    local tmp=$(mktemp -d); local pids=()
    for i in $(seq 0 $((SERVER_COUNT - 1))); do
        local host=${SERVERS[$i]} user=${SSH_USERS[$i]} port=${SSH_PORTS[$i]}
        (
            local dv cv
            dv=$(ssh -p "$port" -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no \
                "${user}@${host}" "docker --version 2>/dev/null || echo NOT_FOUND")
            cv=$(ssh -p "$port" -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no \
                "${user}@${host}" "docker compose version 2>/dev/null || docker-compose --version 2>/dev/null || echo NOT_FOUND")
            echo "${dv}||${cv}" > "${tmp}/r_${i}"
        ) &
        pids+=($!)
    done
    run_parallel "${pids[@]}"
    echo ""
    local all_ok=true
    for i in $(seq 0 $((SERVER_COUNT - 1))); do
        local host=${SERVERS[$i]}
        local r=$(cat "${tmp}/r_${i}" 2>/dev/null || echo "NOT_FOUND||NOT_FOUND")
        local dv=$(echo "$r" | cut -d'|' -f1)
        local cv=$(echo "$r" | cut -d'|' -f3)
        if echo "$dv$cv" | grep -q "NOT_FOUND"; then
            fail "${host}"
            echo "$dv" | grep -q "NOT_FOUND" && info "Docker chưa cài"
            echo "$cv" | grep -q "NOT_FOUND" && info "Docker Compose chưa cài"
            all_ok=false
        else
            ok "${host}"
            info "Docker  : $(echo "$dv" | tr -s ' ')"
            info "Compose : $(echo "$cv" | tr -s ' ')"
        fi
    done
    rm -rf "$tmp"
    [ "$all_ok" = true ] || { echo ""; fail "Một số server thiếu Docker/Compose. Dừng lại."; return 1; }
}

# =========================================
# Function: deploy
# =========================================
do_deploy() {
    echo ""
    echo "  ════════════════════════════════════════════════════"
    echo "  Action     : deploy"
    echo "  Remote dir : ${REMOTE_DIR}"
    echo "  Server(s)  :"
    for i in $(seq 0 $((SERVER_COUNT - 1))); do
        echo "    #$((i+1))  ${SSH_USERS[$i]}@${SERVERS[$i]}:${SSH_PORTS[$i]}"
    done
    echo "  Copy       : tất cả nội dung → ${REMOTE_DIR}/"
    echo "  ════════════════════════════════════════════════════"
    echo ""
    read -p "  Tiếp tục? (yes/no): " confirm
    [[ "$confirm" == "yes" ]] || { echo "Hủy."; return 0; }

    check_ssh    || return 1
    check_docker || return 1

    step "[3] Copy files & docker-compose up -d..."
    echo "  Đang deploy ${SERVER_COUNT} server cùng lúc..."
    local tmp=$(mktemp -d); local pids=()

    for i in $(seq 0 $((SERVER_COUNT - 1))); do
        local host=${SERVERS[$i]} user=${SSH_USERS[$i]} port=${SSH_PORTS[$i]}
        local rf="${tmp}/r_${i}"
        (
            ssh -p "$port" -o StrictHostKeyChecking=no "${user}@${host}" \
                "mkdir -p ${REMOTE_DIR}" &>/dev/null \
                || { echo "fail: không tạo được thư mục" > "$rf"; exit 1; }
            # Copy toàn bộ nội dung LOCAL_DIR lên REMOTE_DIR (y hệt cấu trúc local)
            if command -v rsync &>/dev/null; then
                rsync -az -e "ssh -p ${port} -o StrictHostKeyChecking=no" \
                    --exclude='.git' \
                    "${LOCAL_DIR}/" "${user}@${host}:${REMOTE_DIR}/" &>/dev/null \
                    || { echo "fail: copy files thất bại" > "$rf"; exit 1; }
            else
                for item in compose configs data scripts deploy; do
                    local src="${LOCAL_DIR}/${item}"
                    [ ! -e "$src" ] && continue
                    scp -P "$port" -o StrictHostKeyChecking=no -r \
                        "$src" "${user}@${host}:${REMOTE_DIR}/" &>/dev/null \
                        || { echo "fail: copy ${item} thất bại" > "$rf"; exit 1; }
                done
            fi
            ssh -p "$port" -o StrictHostKeyChecking=no "${user}@${host}" "
                cd ${REMOTE_DIR}
                docker compose -f ${COMPOSE_FILE} up -d 2>/dev/null || docker-compose -f ${COMPOSE_FILE} up -d
            " &>/dev/null || { echo "fail: docker-compose up -d thất bại" > "$rf"; exit 1; }
            echo "ok" > "$rf"
        ) &
        pids+=($!)
    done
    run_parallel "${pids[@]}"

    echo ""
    local fail_list=()
    for i in $(seq 0 $((SERVER_COUNT - 1))); do
        local host=${SERVERS[$i]} user=${SSH_USERS[$i]}
        local r=$(cat "${tmp}/r_${i}" 2>/dev/null || echo "fail: không có kết quả")
        [ "$r" = "ok" ] && ok "${user}@${host}" || { fail "${user}@${host} — ${r#fail: }"; fail_list+=("$host"); }
    done
    rm -rf "$tmp"

    echo ""
    echo "  ════════════════════════════════════════════════════"
    if [ ${#fail_list[@]} -eq 0 ]; then
        ok "Tất cả ${SERVER_COUNT} server deploy thành công."
    else
        fail "Deploy thất bại trên: ${fail_list[*]}"; return 1
    fi
    echo "  ════════════════════════════════════════════════════"
}

# =========================================
# Function: delete
# =========================================
do_delete() {
    echo ""
    echo "  ════════════════════════════════════════════════════"
    echo "  Action     : delete"
    echo "  Remote dir : ${REMOTE_DIR}"
    echo "  Server(s)  :"
    for i in $(seq 0 $((SERVER_COUNT - 1))); do
        echo "    #$((i+1))  ${SSH_USERS[$i]}@${SERVERS[$i]}:${SSH_PORTS[$i]}"
    done
    echo -e "  ${RED}⚠️  Sẽ chạy docker-compose down -v và xóa ${REMOTE_DIR}${NC}"
    echo "  ════════════════════════════════════════════════════"
    echo ""
    read -p "  Tiếp tục? (yes/no): " confirm
    [[ "$confirm" == "yes" ]] || { echo "Hủy."; return 0; }

    check_ssh    || return 1
    check_docker || return 1

    step "[3] Kiểm tra thư mục & docker-compose.yml..."
    echo "  Đang kiểm tra ${SERVER_COUNT} server cùng lúc..."
    local tmp_check=$(mktemp -d); local pids=()

    for i in $(seq 0 $((SERVER_COUNT - 1))); do
        local host=${SERVERS[$i]} user=${SSH_USERS[$i]} port=${SSH_PORTS[$i]}
        (
            if ! ssh -p "$port" -o StrictHostKeyChecking=no "${user}@${host}" \
                "[ -d ${REMOTE_DIR} ]" &>/dev/null; then
                echo "no_dir" > "${tmp_check}/r_${i}"
            elif ssh -p "$port" -o StrictHostKeyChecking=no "${user}@${host}" \
                "[ -f ${REMOTE_DIR}/${COMPOSE_FILE} ]" &>/dev/null; then
                echo "has_compose" > "${tmp_check}/r_${i}"
            else
                echo "no_compose" > "${tmp_check}/r_${i}"
            fi
        ) &
        pids+=($!)
    done
    run_parallel "${pids[@]}"

    echo ""
    local all_ok=true
    for i in $(seq 0 $((SERVER_COUNT - 1))); do
        local host=${SERVERS[$i]}
        local r=$(cat "${tmp_check}/r_${i}" 2>/dev/null || echo "no_dir")
        case "$r" in
            has_compose) ok "${host} — có ${COMPOSE_FILE} → sẽ down -v rồi xóa" ;;
            no_compose)  warn "${host} — thư mục tồn tại nhưng không có ${COMPOSE_FILE} → sẽ xóa thư mục" ;;
            no_dir)      fail "${host} — thư mục ${REMOTE_DIR} không tồn tại, chưa deploy?"; all_ok=false ;;
        esac
    done

    if [ "$all_ok" = false ]; then
        rm -rf "$tmp_check"; fail "Một số server chưa deploy. Dừng lại."; return 1
    fi

    step "[4] docker-compose down -v + xóa thư mục..."
    echo "  Đang xử lý ${SERVER_COUNT} server cùng lúc..."
    local tmp_del=$(mktemp -d); pids=()

    for i in $(seq 0 $((SERVER_COUNT - 1))); do
        local host=${SERVERS[$i]} user=${SSH_USERS[$i]} port=${SSH_PORTS[$i]}
        local cr=$(cat "${tmp_check}/r_${i}" 2>/dev/null || echo "no_dir")
        local rf="${tmp_del}/r_${i}"
        (
            if [ "$cr" = "has_compose" ]; then
                ssh -p "$port" -o StrictHostKeyChecking=no "${user}@${host}" "
                    cd ${REMOTE_DIR}
                    docker compose -f ${COMPOSE_FILE} down -v 2>/dev/null || docker-compose -f ${COMPOSE_FILE} down -v
                " &>/dev/null || { echo "fail: docker-compose down -v thất bại" > "$rf"; exit 1; }
            fi
            ssh -p "$port" -o StrictHostKeyChecking=no "${user}@${host}" \
                "rm -rf ${REMOTE_DIR}" &>/dev/null \
                || { echo "fail: không xóa được thư mục" > "$rf"; exit 1; }
            echo "ok" > "$rf"
        ) &
        pids+=($!)
    done
    run_parallel "${pids[@]}"
    rm -rf "$tmp_check"

    echo ""
    local fail_list=()
    for i in $(seq 0 $((SERVER_COUNT - 1))); do
        local host=${SERVERS[$i]} user=${SSH_USERS[$i]}
        local r=$(cat "${tmp_del}/r_${i}" 2>/dev/null || echo "fail: không có kết quả")
        [ "$r" = "ok" ] && ok "${user}@${host}" || { fail "${user}@${host} — ${r#fail: }"; fail_list+=("$host"); }
    done
    rm -rf "$tmp_del"

    echo ""
    echo "  ════════════════════════════════════════════════════"
    if [ ${#fail_list[@]} -eq 0 ]; then
        ok "Tất cả ${SERVER_COUNT} server đã xóa thành công."
    else
        fail "Xóa thất bại trên: ${fail_list[*]}"; return 1
    fi
    echo "  ════════════════════════════════════════════════════"
}

# =========================================
# Function: chạy script trên remote
# =========================================
run_remote_script() {
    local script_path="$1"
    local remote_script="${REMOTE_DIR}/${script_path}"

    step "Chạy $(basename ${script_path}) trên ${SERVER_COUNT} server..."
    local tmp=$(mktemp -d); local pids=()

    for i in $(seq 0 $((SERVER_COUNT - 1))); do
        local host=${SERVERS[$i]} user=${SSH_USERS[$i]} port=${SSH_PORTS[$i]}
        local rf="${tmp}/r_${i}"
        (
            ssh -p "$port" -o StrictHostKeyChecking=no "${user}@${host}" \
                "bash ${remote_script}" &>/dev/null \
                && echo "ok" > "$rf" || echo "fail" > "$rf"
        ) &
        pids+=($!)
    done
    run_parallel "${pids[@]}"

    echo ""
    for i in $(seq 0 $((SERVER_COUNT - 1))); do
        local host=${SERVERS[$i]} user=${SSH_USERS[$i]}
        local r=$(cat "${tmp}/r_${i}" 2>/dev/null || echo "fail")
        [ "$r" = "ok" ] && ok "${user}@${host}" || fail "${user}@${host} — thất bại"
    done
    rm -rf "$tmp"
}

# =========================================
# Function: menu script phụ
# =========================================
run_other_script() {
    while true; do
        echo ""
        echo "  Chọn script (chạy trên tất cả ${SERVER_COUNT} server):"
        echo "    1) Gen dữ liệu"
        echo "    2) Check dữ liệu đã gen"
        echo "    3) Restore"
        echo "    4) Rollback"
        echo "    5) Quay lại"
        echo ""
        read -p "  Chọn [1-5]: " s
        case "$s" in
            1) run_remote_script "scripts/generate/generate_moodle_db.sh" ;;
            2) run_remote_script "scripts/check/check_moodle_db.sh" ;;
            3) run_remote_script "scripts/recovery/main_restore.sh" ;;
            4) run_remote_script "scripts/recovery/main_rollback.sh" ;;
            5) break ;;
            *) warn "Nhập 1-5." ;;
        esac
    done
}

# =========================================
# MAIN LOOP
# =========================================
declare -a SERVERS=() SSH_PORTS=() SSH_USERS=()
SERVER_COUNT=0

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "  DEPLOY / DELETE MARIADB VIA DOCKER-COMPOSE"
echo "╚══════════════════════════════════════════════════════╝"

while true; do
    echo ""
    echo "  ── Menu chính ──"
    echo "    1) Deploy  — copy files + docker-compose up -d"
    echo "    2) Delete  — docker-compose down -v + xóa thư mục"
    echo "    3) Quit"
    echo ""
    read -p "  Chọn [1-3]: " action

    case "$action" in
        1)
            input_servers
            do_deploy || true
            echo ""
            while true; do
                echo "  Tiếp theo?"
                echo "    1) Quay lại menu chính"
                echo "    2) Quit"
                echo ""
                read -p "  Chọn [1-2]: " nx
                case "$nx" in
                    1) break ;;
                    2) echo ""; echo "  Thoát."; echo ""; exit 0 ;;
                    *) warn "Nhập 1-2." ;;
                esac
            done ;;
        2)
            input_servers
            do_delete || true ;;
        3) echo ""; echo "  Thoát."; echo ""; exit 0 ;;
        *) warn "Nhập 1-3." ;;
    esac
done
