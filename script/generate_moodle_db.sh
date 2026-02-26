#!/bin/bash

# =========================================
# Config
# =========================================
CONTAINER="mariadb-104"
MYSQL_USER="root"
MYSQL_PASS="rootpassword"
DATABASES=(
  "cbb395d7-5ba7-4bb1-b89b-23b71d4051b4"
  "50006e43-0daa-4c0d-8815-040a570a3940"
)

# Số lượng thêm mỗi lần chạy
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
# Helper
# =========================================
mysql_exec() {
  docker exec -i "$CONTAINER" mysql -u "$MYSQL_USER" -p"$MYSQL_PASS" 2>/dev/null
}


log() { echo "  [$(date '+%H:%M:%S')] $1"; }

# =========================================
# Setup tables (idempotent)
# =========================================
setup_tables() {
  local DB=$1
  log "Setup tables..."
  mysql_exec << SQL
CREATE DATABASE IF NOT EXISTS \`$DB\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE \`$DB\`;

CREATE TABLE IF NOT EXISTS mdl_user (
  id         BIGINT AUTO_INCREMENT PRIMARY KEY,
  username   VARCHAR(100),
  email      VARCHAR(200),
  firstname  VARCHAR(100),
  lastname   VARCHAR(100),
  password   VARCHAR(255),
  bio        TEXT,
  city       VARCHAR(100),
  country    VARCHAR(2),
  created_at DATETIME DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS mdl_course (
  id         BIGINT AUTO_INCREMENT PRIMARY KEY,
  fullname   VARCHAR(255),
  shortname  VARCHAR(100),
  summary    TEXT,
  category   INT,
  startdate  DATETIME,
  enddate    DATETIME,
  created_at DATETIME DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS mdl_enrol (
  id          BIGINT AUTO_INCREMENT PRIMARY KEY,
  userid      BIGINT,
  courseid    BIGINT,
  status      TINYINT DEFAULT 0,
  enrolled_at DATETIME DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS mdl_forum_posts (
  id         BIGINT AUTO_INCREMENT PRIMARY KEY,
  userid     BIGINT,
  courseid   BIGINT,
  subject    VARCHAR(255),
  message    LONGTEXT,
  created_at DATETIME DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS mdl_grade_grades (
  id         BIGINT AUTO_INCREMENT PRIMARY KEY,
  userid     BIGINT,
  courseid   BIGINT,
  itemid     BIGINT,
  finalgrade DECIMAL(10,5),
  feedback   TEXT,
  created_at DATETIME DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS mdl_logstore (
  id         BIGINT AUTO_INCREMENT PRIMARY KEY,
  userid     BIGINT,
  courseid   BIGINT,
  action     VARCHAR(100),
  target     VARCHAR(100),
  ip         VARCHAR(45),
  data       TEXT,
  created_at DATETIME DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS mdl_assign (
  id          BIGINT AUTO_INCREMENT PRIMARY KEY,
  userid      BIGINT,
  courseid    BIGINT,
  title       VARCHAR(255),
  submission  LONGTEXT,
  grade       DECIMAL(10,2),
  status      VARCHAR(20) DEFAULT 'submitted',
  submitted_at DATETIME DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS mdl_quiz (
  id          BIGINT AUTO_INCREMENT PRIMARY KEY,
  userid      BIGINT,
  courseid    BIGINT,
  quiz_name   VARCHAR(255),
  score       DECIMAL(5,2),
  max_score   DECIMAL(5,2),
  attempt     TINYINT DEFAULT 1,
  time_taken  INT COMMENT 'seconds',
  started_at  DATETIME DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS mdl_message (
  id          BIGINT AUTO_INCREMENT PRIMARY KEY,
  from_userid BIGINT,
  to_userid   BIGINT,
  subject     VARCHAR(255),
  body        TEXT,
  is_read     TINYINT DEFAULT 0,
  sent_at     DATETIME DEFAULT NOW()
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

  log "Inserting $BATCH_ENROL enrolments..."
  mysql_exec << SQL
USE \`$DB\`;
INSERT INTO mdl_enrol (userid, courseid, status)
SELECT
  FLOOR(RAND()*(SELECT MAX(id) FROM mdl_user))+1,
  FLOOR(RAND()*(SELECT MAX(id) FROM mdl_course))+1,
  FLOOR(RAND()*2)
FROM ($(generate_seq $BATCH_ENROL)) t;
SQL

  log "Inserting $BATCH_FORUM forum posts..."
  mysql_exec << SQL
USE \`$DB\`;
INSERT INTO mdl_forum_posts (userid, courseid, subject, message)
SELECT
  FLOOR(RAND()*(SELECT MAX(id) FROM mdl_user))+1,
  FLOOR(RAND()*(SELECT MAX(id) FROM mdl_course))+1,
  CONCAT('Post subject ', seq),
  REPEAT(CONCAT('Forum content ', seq, ' - Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. '), 20)
FROM ($(generate_seq $BATCH_FORUM)) t;
SQL

  log "Inserting $BATCH_GRADES grades..."
  mysql_exec << SQL
USE \`$DB\`;
INSERT INTO mdl_grade_grades (userid, courseid, itemid, finalgrade, feedback)
SELECT
  FLOOR(RAND()*(SELECT MAX(id) FROM mdl_user))+1,
  FLOOR(RAND()*(SELECT MAX(id) FROM mdl_course))+1,
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
  FLOOR(RAND()*(SELECT MAX(id) FROM mdl_user))+1,
  FLOOR(RAND()*(SELECT MAX(id) FROM mdl_course))+1,
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
  FLOOR(RAND()*(SELECT MAX(id) FROM mdl_user))+1,
  FLOOR(RAND()*(SELECT MAX(id) FROM mdl_course))+1,
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
  FLOOR(RAND()*(SELECT MAX(id) FROM mdl_user))+1,
  FLOOR(RAND()*(SELECT MAX(id) FROM mdl_user))+1,
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
  FLOOR(RAND()*(SELECT MAX(id) FROM mdl_user))+1,
  FLOOR(RAND()*(SELECT MAX(id) FROM mdl_course))+1,
  ELT(1+FLOOR(RAND()*4),'viewed','created','updated','deleted'),
  ELT(1+FLOOR(RAND()*5),'course','user','forum','grade','assign'),
  CONCAT(FLOOR(RAND()*255),'.',FLOOR(RAND()*255),'.',FLOOR(RAND()*255),'.',FLOOR(RAND()*255)),
  REPEAT('Log context data. ', 8)
FROM ($(generate_seq $BATCH_LOGS)) t;
SQL
}

# =========================================
# Helper: generate sequence SQL
# =========================================
generate_seq() {
  local N=$1
  # Tạo sequence 1..N dùng CROSS JOIN
  echo "SELECT a.N + b.N*10 + c.N*100 + d.N*1000 + e.N*10000 + 1 AS seq
    FROM
      (SELECT 0 AS N UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) a
      CROSS JOIN (SELECT 0 AS N UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) b
      CROSS JOIN (SELECT 0 AS N UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) c
      CROSS JOIN (SELECT 0 AS N UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) d
      CROSS JOIN (SELECT 0 AS N UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) e
    WHERE a.N + b.N*10 + c.N*100 + d.N*1000 + e.N*10000 + 1 <= $N"
}



# =========================================
# Run
# =========================================
echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "  Moodle Data Generator"
echo "  Started: $(date '+%Y-%m-%d %H:%M:%S')"
echo "╚══════════════════════════════════════════════════════╝"

for DB in "${DATABASES[@]}"; do
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  DB: $DB"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  setup_tables "$DB"
  insert_data  "$DB"
done

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "  DONE: $(date '+%Y-%m-%d %H:%M:%S')"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
