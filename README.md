# 🗄️ lab-mariadb

Bài thực hành vận hành MariaDB với Docker — tập trung vào kịch bản **xử lý sự cố**: backup → restore → rollback.

---

## Mục lục

1. [Tổng quan kiến trúc](#1-tổng-quan-kiến-trúc)
2. [Cấu trúc thư mục](#2-cấu-trúc-thư-mục)
3. [Yêu cầu môi trường](#3-yêu-cầu-môi-trường)
4. [Deploy & khởi động](#4-deploy--khởi-động)
5. [Chuẩn bị dữ liệu thực hành](#5-chuẩn-bị-dữ-liệu-thực-hành)
6. [Kịch bản xử lý sự cố](#6-kịch-bản-xử-lý-sự-cố)
   - 6.1 [Restore: PRIMARY nhận data từ STANDBY](#61-restore-primary-nhận-data-từ-standby)
   - 6.2 [Rollback: hoàn tác restore](#62-rollback-hoàn-tác-restore)
7. [Luồng tổng thể](#7-luồng-tổng-thể)
8. [Tham khảo nhanh — các lệnh thủ công](#8-tham-khảo-nhanh--các-lệnh-thủ-công)

---

## 1. Tổng quan kiến trúc

### Mariadb StandBy

```
                    ┌───────────────────────────────────────────┐
                    │              Máy điều khiển               │
                    │            (chạy deploy.sh)               │
                    └───────────┬───────────────────────────────┘
                                │ SSH + SCP
               ┌────────────────┴────────────────┐
               ▼                                 ▼
   ┌───────────────────────┐         ┌───────────────────────┐
   │       PRIMARY         │         │       STANDBY         │
   │  DB gốc / mục tiêu    │◄────────│  DB tạm / backup      │
   │  mariadb-104          │  rsync  │  mariadb-104          │
   │  port 3306            │         │  port 3306            │
   │  phpMyAdmin :8088     │         │  phpMyAdmin :8088     │
   └───────────────────────┘         └───────────────────────┘
```

**PRIMARY** — DB chính, phục vụ production. Khi bị sự cố, cần nhận lại data từ STANDBY.

**STANDBY** — DB dự phòng, chứa data mới nhất trong lúc PRIMARY ngừng hoạt động. Là nguồn để restore.


### Mariadb Cluster

```
        Client
           │
           │
        HAProxy
           │
   ┌───────┼────────┐
   │       │        │
MariaDB1 MariaDB2 MariaDB3
 Galera   Galera   Galera
```

---

## 2. Cấu trúc thư mục

```
lab-mariadb/
│
├── compose/                         # Docker stack
│   ├── docker-compose.yml           # MariaDB single + phpMyAdmin
│   └── docker-compose-galera.yml    # Galera cluster + HAProxy
├── configs/                         # Config service
│   ├── mariadb/
│   │   ├── my.cnf
│   │   └── galera.cnf
│   └── haproxy/
│       └── haproxy.cfg
├── data/                            # Volume data (lab only)
│   ├── galera/
│   │   ├── node1
│   │   ├── node2
│   │   └── node3
│   └── standalone/
│       └── mysql-104
├── scripts/                         # Scripts thao tác DB
│   ├── generate/
│   │   ├── generate_moodle_db.sh
│   │   └── generate_moodle_auto_db.sh
│   ├── check/
│   │   ├── check_moodle_db.sh
│   │   └── check_cron_ba.sh
│   └── recovery/
│       ├── main_restore.sh
│       └── main_rollback.sh
├── deploy/                          # Script triển khai infra
│   └── deploy.sh
└── README.md
```

---

## 3. Yêu cầu môi trường

| Thành phần | Yêu cầu |
|---|---|
| Docker | ≥ 20.x |
| Docker Compose | v2 (`docker compose`) hoặc v1 (`docker-compose`) |
| SSH | Key-based auth (không password) từ máy điều khiển đến các server |
| rsync | Cần cài trên cả STANDBY lẫn PRIMARY (cho bước transfer dump) |
| SSH key (STANDBY→PRIMARY) | `main_restore.sh` dùng rsync trực tiếp giữa 2 server |

**Kiểm tra nhanh trên server mục tiêu:**
```bash
docker --version
docker compose version
rsync --version
```

---

## 4. Deploy & khởi động

### 4.1 Chạy thủ công trên 1 server

```bash
# Clone project về server
git clone <repo> lab-mariadb && cd lab-mariadb

# Khởi động MariaDB + phpMyAdmin
docker compose up -d

# Kiểm tra container
docker ps
```

Sau khi khởi động:
- **MariaDB**: `localhost:3306` — user `root` / pass `rootpassword`
- **phpMyAdmin**: `http://<server-ip>:8088`

### 4.2 Deploy lên nhiều server bằng `deploy.sh`

```bash
chmod +x deploy.sh
./deploy.sh
```

Script sẽ hỏi lần lượt:
1. Số lượng server
2. Host IP, SSH User, SSH Port cho từng server
3. Xác nhận trước khi thực thi

Các bước tự động: kiểm tra SSH → kiểm tra Docker → copy files → `docker compose up -d`.

> **Lưu ý:** Deploy chạy song song trên tất cả server cùng lúc.

### 4.3 Xóa deployment

Chọn `2) Delete` trong menu `deploy.sh`. Script sẽ chạy `docker compose down -v` và xóa thư mục `/root/mariadb` trên remote.

---

## 5. Chuẩn bị dữ liệu thực hành

### 5.1 Tạo dữ liệu giả lập Moodle

```bash
# Chạy trên server (trong container chạy rồi)
bash script/generate_moodle_db.sh
```

Script tạo 2 database với schema mô phỏng Moodle, chèn hàng trăm nghìn bản ghi:

| Bảng | Số lượng (mỗi lần chạy) |
|---|---|
| `mdl_user` | 10,000 |
| `mdl_course` | 1,000 |
| `mdl_enrol` | 50,000 |
| `mdl_forum_posts` | 30,000 |
| `mdl_grade_grades` | 50,000 |
| `mdl_logstore` | 100,000 |
| `mdl_assign` | 20,000 |
| `mdl_quiz` | 20,000 |
| `mdl_message` | 30,000 |

> Script có tính **idempotent** — chạy nhiều lần sẽ tiếp tục cộng dồn dữ liệu.

### 5.2 Giả lập hoạt động liên tục

```bash
bash script/insert_auto.sh
```

Mỗi 5 giây, script chèn thêm log, forum post, assignment, quiz, message vào cả 2 DB — giả lập hệ thống đang có người dùng thực sự. Nhấn `Ctrl+C` để dừng, script sẽ in tổng kết.

### 5.3 Kiểm tra trạng thái DB

```bash
bash script/check_moodle_db.sh
```

Hiển thị: kích thước DB, số bảng, row count chính xác từng bảng, checksum.

---

## 6. Kịch bản xử lý sự cố

### Bối cảnh

```
Bình thường:   Client ──► PRIMARY

Khi PRIMARY lỗi:
               Client ──► STANDBY  (chuyển hướng tạm)
                          STANDBY accumulates new data...

Sau khi PRIMARY phục hồi:
               PRIMARY cần nhận lại toàn bộ data từ STANDBY
               → Chạy main_restore.sh
```

---

### 6.1 Restore: PRIMARY nhận data từ STANDBY

```bash
bash script/main_restore.sh
```

**Script yêu cầu nhập:**

| Thông tin | Ý nghĩa |
|---|---|
| STANDBY host/user/port | SSH vào máy chứa data mới |
| STANDBY container name | Tên Docker container MariaDB trên STANDBY |
| STANDBY DB name/user/pass | Thông tin kết nối DB nguồn |
| PRIMARY host/user/port | SSH vào máy đích cần restore |
| PRIMARY container name | Tên Docker container MariaDB trên PRIMARY |
| PRIMARY DB name/user/pass | Thông tin kết nối DB đích |
| Tables verify (tuỳ chọn) | Tên bảng cần đếm row để verify, để trống = tất cả |

**Các bước script thực hiện:**

```
[0/6]  Kiểm tra SSH + DB cả 2 phía
[1/6]  Backup DB hiện tại trên PRIMARY  →  /tmp/migrate/backup_<db>_<timestamp>.sql.gz
[2/6]  Dump DB từ STANDBY + đếm row snapshot
[3/6]  rsync dump file: STANDBY → PRIMARY  (trực tiếp, không qua máy điều khiển)
[4/6]  Kiểm tra integrity: MD5 checksum + file size
[5/6]  DROP & recreate DB trên PRIMARY, import dump
[6/6]  Verify row count: so sánh PRIMARY sau restore với snapshot STANDBY lúc dump
```

> ⚠️ **Yêu cầu bắt buộc:** SSH key từ STANDBY đến PRIMARY phải được cấu hình trước (dùng cho rsync trực tiếp).
>
> ```bash
> # Trên máy STANDBY
> ssh-copy-id -p <PRI_PORT> root@<PRI_HOST>
> ```

**Kết quả restore thành công:**
```
  Rows STANDBY (lúc dump)    : 360000
  Rows PRIMARY (sau restore) : 360000
✅ VERIFY OK: Rows khớp (360000)
```

**Nếu restore thất bại hoặc verify fail** — script KHÔNG tự xóa backup. File backup vẫn còn trên PRIMARY để rollback.

---

### 6.2 Rollback: hoàn tác restore

Dùng khi restore xong nhưng phát hiện vấn đề và cần quay về trạng thái trước.

```bash
bash script/main_rollback.sh
```

**Script yêu cầu nhập:**

| Thông tin | Ý nghĩa |
|---|---|
| TARGET host/user/port | Server cần rollback (thường là PRIMARY) |
| TARGET container/DB | Thông tin Docker + DB |
| Thư mục backup | Nơi chứa file `backup_*.sql.gz` (mặc định `/tmp/migrate`) |

**Script tự động:**
1. Tìm file backup mới nhất khớp pattern `backup_<db>_*.sql.gz`
2. Hiển thị tên file + thời điểm tạo để xác nhận
3. DROP & recreate DB, import lại từ backup
4. Hỏi có xóa file backup sau khi rollback xong không

---

## 7. Luồng tổng thể

```
┌─────────────────────────────────────────────────────────┐
│                    VÒNG ĐỜI DỮ LIỆU                     │
└─────────────────────────────────────────────────────────┘

  deploy.sh                  Khởi động MariaDB lên server(s)
       │
       ▼
  generate_moodle_db.sh      Tạo dữ liệu thực hành
       │
       ▼
  insert_auto.sh             Giả lập hoạt động (tùy chọn)
       │
       ▼
  [Sự cố xảy ra trên PRIMARY]
       │
       ▼
  main_restore.sh            Restore data STANDBY → PRIMARY
       │
       ├── Thành công ──►  check_moodle_db.sh  (kiểm tra lại)
       │
       └── Có vấn đề   ──► main_rollback.sh    (hoàn tác)
```

---

## 8. Tham khảo nhanh — các lệnh thủ công

### Backup thủ công (trong container)

```bash
# Dump toàn bộ DB ra file nén
docker exec mariadb-104 mysqldump \
  --single-transaction --routines --triggers \
  -uroot -prootpassword mydb \
  | gzip > /tmp/backup_mydb_$(date +%Y%m%d_%H%M%S).sql.gz
```

### Restore thủ công từ file dump

```bash
# Giải nén và import vào DB
gunzip -c /tmp/backup_mydb_*.sql.gz \
  | docker exec -i mariadb-104 mysql -uroot -prootpassword mydb
```

### Kiểm tra row count nhanh

```bash
docker exec mariadb-104 mysql -uroot -prootpassword -e \
  "SELECT table_name, table_rows
   FROM information_schema.tables
   WHERE table_schema = 'mydb'
   ORDER BY table_rows DESC;"
```

### Xem log container

```bash
docker logs -f mariadb-104
```

### Kết nối shell vào MariaDB

```bash
docker exec -it mariadb-104 mysql -uroot -prootpassword
```

---

> **Ghi chú bảo mật:** Các giá trị `rootpassword`, `mypasswordHacker` trong project này chỉ dùng cho **môi trường lab**. Không dùng cho production.
