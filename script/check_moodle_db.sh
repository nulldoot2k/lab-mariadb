#!/bin/bash

# =========================================
# Config
# =========================================
CONTAINER="mariadb-104"
MYSQL_USER="root"
MYSQL_PASS="rootpassword"
DB1="cbb395d7-5ba7-4bb1-b89b-23b71d4051b4"
DB2="50006e43-0daa-4c0d-8815-040a570a3940"

# =========================================
# Helper
# =========================================
mysql_exec() {
  docker exec -i "$CONTAINER" mysql -u "$MYSQL_USER" -p"$MYSQL_PASS" --table 2>/dev/null
}

get_tables() {
  docker exec -i "$CONTAINER" mysql -u "$MYSQL_USER" -p"$MYSQL_PASS" -N 2>/dev/null -e \
    "SELECT table_name FROM information_schema.tables WHERE table_schema = '$1' ORDER BY table_name;"
}

# =========================================
# Check function
# =========================================
check_db() {
  local DB=$1

  echo ""
  echo "╔══════════════════════════════════════════════════════╗"
  echo "  DB: $DB"
  echo "╚══════════════════════════════════════════════════════╝"

  # --- Size ---
  echo ""
  echo "▶ SIZE"
  mysql_exec << SQL
SELECT
  ROUND(SUM(data_length + index_length) / 1024 / 1024, 2) AS 'Total Size (MB)',
  COUNT(*) AS 'Total Tables'
FROM information_schema.tables
WHERE table_schema = '$DB';
SQL

  # --- Row Count ---
  echo ""
  echo "▶ ROW COUNT (exact)"

  TABLES=$(get_tables "$DB")

  UNION_SQL=""
  for TABLE in $TABLES; do
    [ -n "$UNION_SQL" ] && UNION_SQL="$UNION_SQL UNION ALL"
    UNION_SQL="$UNION_SQL SELECT '$TABLE' AS table_name, COUNT(*) AS records FROM \`$DB\`.\`$TABLE\`"
  done

  mysql_exec << SQL
SELECT * FROM ($UNION_SQL) t ORDER BY table_name;

SELECT
  COUNT(*)        AS total_tables,
  SUM(records)    AS total_records
FROM ($UNION_SQL) t;
SQL

  # --- Checksum ---
  echo ""
  echo "▶ CHECKSUM"
  CHECKSUM_TABLES=$(echo "$TABLES" | tr '\n' ',' | sed "s/,$//" | sed "s/[^,]*/\`$DB\`.\`&\`/g")
  mysql_exec << SQL
CHECKSUM TABLE $CHECKSUM_TABLES;
SQL

}

# =========================================
# Run
# =========================================
echo ""
echo "  Snapshot: $(date '+%Y-%m-%d %H:%M:%S')"

check_db "$DB1"
check_db "$DB2"

echo ""
echo "════════════════════════════════════════"
echo "  DONE"
echo "════════════════════════════════════════"
echo ""
