#!/bin/bash

# ============================================================
#  MOODLE DB CHECKER
#  Chạy : bash check_moodle_db.sh
#  Mode : fast (mặc định) | exact | verify
#  Override: MODE=exact bash check_moodle_db.sh
# ============================================================

CONTAINER="mariadb-104"
MYSQL_USER="root"
MYSQL_PASS="rootpassword"

MODE=${MODE:-fast}

# =========================================
# Colors
# =========================================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

ok()   { echo -e "  ${GREEN}✔${NC} $1"; }
fail() { echo -e "  ${RED}✘${NC} $1"; }
warn() { echo -e "  ${YELLOW}⚠${NC}  $1"; }
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
mysql_table() {
  docker exec -i "$CONTAINER" \
    mysql -u"$MYSQL_USER" -p"$MYSQL_PASS" --table 2>/dev/null
}

mysql_q() {
  docker exec "$CONTAINER" \
    mysql -u"$MYSQL_USER" -p"$MYSQL_PASS" -N 2>/dev/null \
    -e "$1"
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
# Load DB từ server
# =========================================
load_databases() {
  mapfile -t ALL_DBS < <(
    mysql_q "SELECT schema_name
             FROM information_schema.schemata
             WHERE schema_name NOT IN (
               'information_schema','performance_schema',
               'mysql','sys','innodb'
             )
             ORDER BY schema_name;"
  )
  if [ ${#ALL_DBS[@]} -eq 0 ]; then
    fail "Không tìm thấy DB nào."; exit 1
  fi
}

# =========================================
# Chọn DB — multi-select, b/q
# =========================================
select_dbs() {
  while true; do
    echo ""
    echo -e "  ${BOLD}Chọn DB để check${NC}"
    sep
    for i in "${!ALL_DBS[@]}"; do
      printf "  ${CYAN}%2d)${NC}  %s\n" "$((i+1))" "${ALL_DBS[$i]}"
    done
    echo -e "  ${CYAN} 0)${NC}  Tất cả"
    echo ""
    dim "  Chọn 1 hoặc nhiều, cách nhau bởi dấu phẩy. Vd: 1,2"
    dim "  q) Thoát"
    echo ""
    read -rp "  Nhập [0-${#ALL_DBS[@]}/q]: " input

    case "${input// /}" in
      q|Q) quit ;;
      0)
        SELECTED_DBS=("${ALL_DBS[@]}")
        return 0
        ;;
    esac

    IFS=',' read -ra choices <<< "${input// /}"
    SELECTED_DBS=()
    local valid=1

    for choice in "${choices[@]}"; do
      if [[ "$choice" =~ ^[0-9]+$ ]] && \
         [ "$choice" -ge 1 ] && \
         [ "$choice" -le "${#ALL_DBS[@]}" ]; then
        SELECTED_DBS+=("${ALL_DBS[$((choice-1))]}")
      else
        warn "'${choice}' không hợp lệ."; valid=0; break
      fi
    done

    [ "$valid" -eq 0 ] && continue
    mapfile -t SELECTED_DBS < <(printf '%s\n' "${SELECTED_DBS[@]}" | sort -u)
    [ "${#SELECTED_DBS[@]}" -gt 0 ] && return 0
  done
}

# =========================================
# Check: FAST
# =========================================
check_fast() {
  local DB=$1
  mysql_table << SQL
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
# Check: EXACT
# =========================================
check_exact() {
  local DB=$1

  mapfile -t TABLES < <(
    mysql_q "SELECT table_name FROM information_schema.tables
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

  mysql_table << SQL
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
# Check: VERIFY
# =========================================
check_verify() {
  local DB=$1

  dim "  fast (estimated)"
  check_fast "$DB"

  echo ""
  dim "  exact (COUNT*)"
  check_exact "$DB"

  echo ""
  echo -e "  ${BOLD}Drift analysis${NC}"
  sep

  mapfile -t TABLES < <(
    mysql_q "SELECT table_name FROM information_schema.tables
             WHERE table_schema='${DB}' ORDER BY table_name;"
  )

  printf "  %-22s %12s %12s %8s\n" "Table" "Est Rows" "Exact Rows" "Drift"
  sep

  for T in "${TABLES[@]}"; do
    local EST EXACT DRIFT
    EST=$(mysql_q "SELECT table_rows FROM information_schema.tables
                   WHERE table_schema='${DB}' AND table_name='${T}';" | tr -d '[:space:]')
    EXACT=$(mysql_q "SELECT COUNT(*) FROM \`${DB}\`.\`${T}\`;" | tr -d '[:space:]')

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
# Run check
# =========================================
run_check() {
  echo ""
  echo -e "  ${BOLD}Snapshot: $(date '+%Y-%m-%d %H:%M:%S')${NC}  ${DIM}mode: ${MODE}${NC}"

  for DB in "${SELECTED_DBS[@]}"; do
    echo ""
    sep
    echo -e "  ${BOLD}DB:${NC} $DB"
    sep
    case "$MODE" in
      fast)   check_fast   "$DB" ;;
      exact)  check_exact  "$DB" ;;
      verify) check_verify "$DB" ;;
      *)
        warn "MODE='$MODE' không hợp lệ. Dùng: fast | exact | verify"
        exit 1
        ;;
    esac
  done

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
dim   "  Container: ${CONTAINER}  |  Mode: ${MODE}"
echo ""

check_container
load_databases

while true; do
  select_dbs
  run_check

  read -rp "  Check tiếp? [y/q]: " again
  case "$again" in
    y|Y) continue ;;
    *)   quit ;;
  esac
done
