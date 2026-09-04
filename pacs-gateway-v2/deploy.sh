#!/bin/bash
set -e

echo "=============================================="
echo "PACS Gateway v2 - Staged Upload Architecture"
echo "=============================================="
echo "   ██████╗██╗      ██████╗ ██╗   ██╗███████╗"
echo "  ██╔════╝██║     ██╔═══██╗██║   ██║██╔════╝"
echo "  ██║     ██║     ██║   ██║██║   ██║███████╗"
echo "  ██║     ██║     ██║   ██║██║   ██║╚════██║"
echo "  ╚██████╗███████╗╚██████╔╝╚██████╔╝███████║"
echo "   ╚═════╝╚══════╝ ╚═════╝  ╚═════╝ ╚══════╝"
echo ""
echo "Mimari: Fuji/PACS -SMB-> yerel disk -inotify-> OBS (tek yönlü)"
echo "        Doktorlar <-SMB- read-only cache-first mount <- OBS"
echo "=============================================="

# ============================================
# 0. PUBLIC ve PRIVATE IP'Yİ AL
# ============================================
PUBLIC_IP=$(curl -s ifconfig.me 2>/dev/null || curl -s icanhazip.com 2>/dev/null)
if [[ -z "$PUBLIC_IP" ]]; then
    read -p "Public IP adresini manuel girin: " PUBLIC_IP
fi
PRIVATE_IP=$(hostname -I | awk '{print $1}')

# ============================================
# 1. DOCKER ve DOCKER COMPOSE KURULUMU
# ============================================
if ! command -v docker &> /dev/null; then
    echo "Docker kurulu değil, kuruluyor..."
    sudo apt update
    sudo apt install -y ca-certificates curl
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt update
    sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    sudo systemctl enable docker
    sudo systemctl start docker
    echo "Docker kurulumu tamamlandı."
else
    echo "Docker zaten kurulu."
fi

# ============================================
# 1.1 inotify-tools KURULUMU
# ============================================
if ! command -v inotifywait &> /dev/null; then
    echo "inotify-tools kurulu değil, kuruluyor..."
    sudo apt update
    sudo apt install -y inotify-tools
fi

# ============================================
# 2. KULLANICIDAN BİLGİLERİ AL (ZORUNLU)
# ============================================
while [[ -z "$ACCESS_KEY" ]]; do
    read -p "Huawei OBS Access Key: " ACCESS_KEY
done

while [[ -z "$SECRET_KEY" ]]; do
    read -sp "Huawei OBS Secret Key: " SECRET_KEY
    echo
done

echo ""
echo "📍 OBS Region seçin:"
echo "  1) tr-west-1 (Istanbul)"
echo "  2) eu-west-1 (Ireland)"
echo "  3) eu-west-2 (London)"
echo "  4) eu-west-3 (Paris)"
echo "  5) eu-west-4 (Frankfurt)"
echo "  6) ap-southeast-1 (Singapore)"
echo "  7) ap-southeast-2 (Tokyo)"
echo "  8) ap-southeast-3 (Seoul)"
echo "  9) cn-north-1 (Beijing)"
echo "  10) us-east-1 (Virginia)"
echo "  11) us-west-1 (California)"
read -p "Seçiminiz (1-11): " REGION_CHOICE

case $REGION_CHOICE in
    1) ENDPOINT="obs.tr-west-1.myhuaweicloud.com" ;;
    2) ENDPOINT="obs.eu-west-1.myhuaweicloud.com" ;;
    3) ENDPOINT="obs.eu-west-2.myhuaweicloud.com" ;;
    4) ENDPOINT="obs.eu-west-3.myhuaweicloud.com" ;;
    5) ENDPOINT="obs.eu-west-4.myhuaweicloud.com" ;;
    6) ENDPOINT="obs.ap-southeast-1.myhuaweicloud.com" ;;
    7) ENDPOINT="obs.ap-southeast-2.myhuaweicloud.com" ;;
    8) ENDPOINT="obs.ap-southeast-3.myhuaweicloud.com" ;;
    9) ENDPOINT="obs.cn-north-1.myhuaweicloud.com" ;;
    10) ENDPOINT="obs.us-east-1.myhuaweicloud.com" ;;
    11) ENDPOINT="obs.us-west-1.myhuaweicloud.com" ;;
    *) echo "Geçersiz seçim, varsayılan tr-west-1 kullanılıyor."; ENDPOINT="obs.tr-west-1.myhuaweicloud.com" ;;
esac
echo "✅ Seçilen endpoint: $ENDPOINT"

while [[ -z "$BUCKET_NAME" ]]; do
    read -p "OBS Bucket Adı: " BUCKET_NAME
done

while [[ -z "$SMB_USER" ]]; do
    read -p "Samba Kullanıcı Adı (örn: pacsuser): " SMB_USER
done

while [[ -z "$SMB_PASS" ]]; do
    read -sp "Samba Şifresi: " SMB_PASS
    echo
done

while [[ -z "$SMTP_MAIL" ]]; do
    read -p "SMTP Mail Adresi: " SMTP_MAIL
done

while [[ -z "$SMTP_PASS" ]]; do
    read -sp "SMTP Uygulama Şifresi: " SMTP_PASS
    echo
done

while [[ -z "$ALERT_MAIL" ]]; do
    read -p "Alert E-posta Adresi: " ALERT_MAIL
done

while [[ -z "$RC_USER" ]]; do
    read -p "Rclone RC Kullanıcı Adı: " RC_USER
done
while [[ -z "$RC_PASS" ]]; do
    read -sp "Rclone RC Şifresi: " RC_PASS
    echo
done

read -p "Staging (yazılabilir) Dizin [varsayılan: /mnt/pacs-hot/local]: " LOCAL_PATH
LOCAL_PATH=${LOCAL_PATH:-/mnt/pacs-hot/local}

read -p "Arşiv (read-only, OBS mount) Dizin [varsayılan: /mnt/pacs-hot/archive-ro]: " RO_MOUNT_PATH
RO_MOUNT_PATH=${RO_MOUNT_PATH:-/mnt/pacs-hot/archive-ro}

echo ""
echo "📦 Yerelden silme eşiği (staging dizinindeki dosyalar OBS'e yüklendikten"
echo "   şu kadar süre sonra yerelden silinir). Birimler: h=saat, d=gün"
echo "   Test için: 3h  |  Prod için: 168h (7 gün) önerilir."
read -p "Silme Eşiği [varsayılan: 3h]: " MAX_AGE_RAW
MAX_AGE_RAW=${MAX_AGE_RAW:-3h}
MAX_AGE_HOURS=$(echo "$MAX_AGE_RAW" | sed -E 's/([0-9]+)h/\1/; s/([0-9]+)d/\1*24/' | bc 2>/dev/null || echo "3")

# ============================================
# 2.1 DOKTOR/FUJI ARŞİV MOUNT'U İÇİN VFS CACHE AYARLARI (DİNAMİK)
# ============================================
echo ""
echo "📦 DOKTOR ARŞİVİ (read-only) VFS CACHE SÜRESİ:"
echo "   Doktorun açtığı bir dosya, bu süre boyunca yerel diskte tutulur."
echo "   Süre içinde tekrar açılırsa OBS'e HİÇ gidilmez, direkt yerelden sunulur."
echo "   Süre dolunca dosya diskten silinir ama OBS'te kalır; bir sonraki"
echo "   istekte otomatik ve şeffaf şekilde tekrar OBS'ten çekilir."
echo "   Birimler: h=saat, d=gün. Örnekler: 720h (30 gün - prod), 3h (test)"
read -p "Arşiv Cache Süresi [varsayılan: 720h]: " RO_CACHE_AGE_RAW
RO_CACHE_AGE=${RO_CACHE_AGE_RAW:-720h}
if [[ ! "$RO_CACHE_AGE" =~ (s|m|h|d)$ ]]; then
    echo "⚠️  Birim belirtilmedi, saat (h) varsayılıyor."
    RO_CACHE_AGE="${RO_CACHE_AGE}h"
fi

echo ""
echo "📦 DOKTOR ARŞİVİ (read-only) VFS CACHE MAKSİMUM BOYUTU:"
echo "   Yerel diskin en fazla ne kadarını bu cache için ayıracağını belirler."
echo "   Kota dolunca en eski kullanılan dosyalar (LRU) otomatik cache'den atılır,"
echo "   tekrar istenirse yine OBS'ten çekilir - veri kaybı olmaz."
echo "   Örnekler: 50G, 100G, 500G, 1T"
read -p "Arşiv Cache Max Boyut [varsayılan: 50G]: " RO_CACHE_SIZE
RO_CACHE_SIZE=${RO_CACHE_SIZE:-50G}

# ============================================
# 3. PORT KONTROLLERİ
# ============================================
echo ""
echo "🔍 Port kontrolleri yapılıyor..."
REQUIRED_PORTS=(139 445 3000 5572 9090 9100 9393)
PORT_ERROR=0

for port in "${REQUIRED_PORTS[@]}"; do
    if sudo ss -tlnp | grep -q ":$port "; then
        echo "⚠️  Port $port zaten kullanımda!"
        PORT_ERROR=1
    else
        echo "✅ Port $port kullanıma uygun."
    fi
done

if [[ $PORT_ERROR -eq 1 ]]; then
    echo ""
    echo "❌ Bazı portlar zaten kullanımda!"
    read -p "Devam etmek istiyor musunuz? (y/N): " CONTINUE
    if [[ ! "$CONTINUE" =~ ^[Yy]$ ]]; then
        echo "Kurulum iptal edildi."
        exit 1
    fi
fi

if command -v ufw &> /dev/null && sudo ufw status | grep -q "Status: active"; then
    echo ""
    echo "🔒 UFW aktif. Gerekli portlar açılıyor..."
    sudo ufw allow 139,445/tcp comment 'SMB'
    sudo ufw allow 3000/tcp comment 'Grafana'
    sudo ufw allow 5572/tcp comment 'Rclone'
    sudo ufw allow 9090/tcp comment 'Prometheus'
    sudo ufw allow 9100/tcp comment 'Node-Exporter'
    sudo ufw allow 9393/tcp comment 'Alertmanager'
fi

# ============================================
# 4. DİZİNLERİ OLUŞTUR
# ============================================
echo ""
echo "📁 Dizinler oluşturuluyor..."
sudo mkdir -p /etc/rclone /opt/pacs-gateway/{config,scripts,prometheus,alertmanager,grafana/dashboards,grafana/provisioning/dashboards,grafana/provisioning/datasources,systemd,logs,state/uploaded}
sudo mkdir -p "$LOCAL_PATH" "$RO_MOUNT_PATH"

cd /opt/pacs-gateway

# ============================================
# 5. RCLONE CONFIG
# ============================================
echo "📝 Rclone config oluşturuluyor..."
cat > config/rclone.conf <<EOF
[obs]
type = s3
provider = HuaweiOBS
access_key_id = $ACCESS_KEY
secret_access_key = $SECRET_KEY
endpoint = $ENDPOINT
acl = private
bucket_acl = private
EOF
sudo cp config/rclone.conf /etc/rclone/rclone.conf
sudo chmod 600 /etc/rclone/rclone.conf

# ============================================
# 6. UPLOAD WATCHER + CLEANUP SCRIPTLERİ
# ============================================
echo "📝 Upload watcher ve cleanup scriptleri yazılıyor..."
cat > scripts/upload-watcher.sh <<'SCRIPTEOF'
#!/bin/bash
set -u
LOCAL_DIR="${LOCAL_DIR:-/mnt/pacs-hot/local}"
BUCKET_NAME="${BUCKET_NAME:-YOUR_BUCKET}"
RCLONE_CONF="${RCLONE_CONF:-/etc/rclone/rclone.conf}"
LOG_FILE="${LOG_FILE:-/opt/pacs-gateway/logs/upload-watcher.log}"
STATE_DIR="${STATE_DIR:-/opt/pacs-gateway/state/uploaded}"
mkdir -p "$STATE_DIR" "$(dirname "$LOG_FILE")"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"; }
log "🚀 Upload watcher başlatıldı: $LOCAL_DIR izleniyor -> obs:${BUCKET_NAME}"
inotifywait -m -r -e close_write --format '%w%f' "$LOCAL_DIR" | while read -r FILEPATH
do
    FILENAME=$(basename "$FILEPATH")
    case "$FILENAME" in
        .*|*.tmp|*.partial|~*) log "⏭️  Geçici dosya atlandı: $FILEPATH"; continue ;;
    esac
    if [[ ! -f "$FILEPATH" ]]; then
        log "⚠️  Dosya bulunamadı: $FILEPATH"; continue
    fi
    RELATIVE_PATH="${FILEPATH#$LOCAL_DIR/}"
    REMOTE_PATH="obs:${BUCKET_NAME}/${RELATIVE_PATH}"
    MARKER_FILE="${STATE_DIR}/${RELATIVE_PATH//\//__}.uploaded"
    if rclone lsf "$REMOTE_PATH" --config "$RCLONE_CONF" &>/dev/null; then
        log "⚠️  ÇAKIŞMA: $REMOTE_PATH zaten OBS'te mevcut. Yükleme ATLANDI."
        continue
    fi
    log "📤 Yükleniyor: $FILEPATH -> $REMOTE_PATH"
    if rclone copyto "$FILEPATH" "$REMOTE_PATH" --config "$RCLONE_CONF" --log-level INFO --log-file "$LOG_FILE"; then
        mkdir -p "$(dirname "$MARKER_FILE")"
        date -u +"%Y-%m-%dT%H:%M:%SZ" > "$MARKER_FILE"
        log "✅ Yükleme tamamlandı: $RELATIVE_PATH"
    else
        log "❌ Yükleme BAŞARISIZ: $RELATIVE_PATH"
    fi
done
SCRIPTEOF

cat > scripts/cleanup-old.sh <<'SCRIPTEOF'
#!/bin/bash
set -u
LOCAL_DIR="${LOCAL_DIR:-/mnt/pacs-hot/local}"
STATE_DIR="${STATE_DIR:-/opt/pacs-gateway/state/uploaded}"
LOG_FILE="${LOG_FILE:-/opt/pacs-gateway/logs/cleanup.log}"
MAX_AGE_HOURS="${MAX_AGE_HOURS:-3}"
mkdir -p "$(dirname "$LOG_FILE")"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"; }
log "🧹 Cleanup başladı (eşik: ${MAX_AGE_HOURS} saat)"
find "$STATE_DIR" -type f -name "*.uploaded" -mmin "+$((MAX_AGE_HOURS * 60))" 2>/dev/null | while read -r MARKER
do
    RELATIVE_PATH=$(basename "$MARKER" .uploaded)
    RELATIVE_PATH="${RELATIVE_PATH//__//}"
    LOCAL_FILE="${LOCAL_DIR}/${RELATIVE_PATH}"
    if [[ -f "$LOCAL_FILE" ]]; then
        rm -f "$LOCAL_FILE"
        log "🗑️  Silindi (OBS'te güvende): $LOCAL_FILE"
    else
        log "ℹ️  Zaten yok: $LOCAL_FILE"
    fi
    rm -f "$MARKER"
done
find "$LOCAL_DIR" -mindepth 1 -type d -empty -delete 2>/dev/null
log "✅ Cleanup tamamlandı"
SCRIPTEOF

chmod +x scripts/upload-watcher.sh scripts/cleanup-old.sh

# ============================================
# 7. PROMETHEUS CONFIG
# ============================================
echo "📝 Prometheus config oluşturuluyor..."
cat > prometheus/prometheus.yml <<EOF
global:
  scrape_interval: 15s
  evaluation_interval: 15s
rule_files:
  - "alert.rules.yml"
alerting:
  alertmanagers:
    - static_configs:
        - targets: ['alertmanager:9393']
scrape_configs:
  - job_name: 'rclone'
    static_configs:
      - targets: ['host.docker.internal:5572']
    basic_auth:
      username: '$RC_USER'
      password: '$RC_PASS'
  - job_name: 'node-exporter'
    static_configs:
      - targets: ['node-exporter:9100']
EOF

# ============================================
# 8. ALARM KURALLARI
# ============================================
echo "📝 Alarm kuralları oluşturuluyor..."
cat > prometheus/alert.rules.yml <<'EOF'
groups:
  - name: pacs_alerts
    rules:
      - alert: RcloneServiceDown
        expr: up{job="rclone"} == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "Rclone RC servisi çöktü!"
          description: "RC API yanıt vermiyor."
      - alert: SambaServiceDown
        expr: up{job="samba"} == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "Samba servisi çalışmıyor!"
          description: "Windows client'lar paylaşıma erişemiyor."
      - alert: HotStorageDiskSpaceWarning
        expr: (node_filesystem_avail_bytes{mountpoint="/mnt/pacs-hot"} / node_filesystem_size_bytes{mountpoint="/mnt/pacs-hot"} * 100) < 20
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Hot disk %80 dolu (uyarı)"
          description: "Staging alanı doluyor."
      - alert: HotStorageDiskSpaceCritical
        expr: (node_filesystem_avail_bytes{mountpoint="/mnt/pacs-hot"} / node_filesystem_size_bytes{mountpoint="/mnt/pacs-hot"} * 100) < 10
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "Hot disk %90 dolu!"
          description: "Upload-watcher ve cleanup'ı kontrol edin."
EOF

# ============================================
# 9. ALERTMANAGER CONFIG
# ============================================
echo "📝 Alertmanager config oluşturuluyor..."
cat > alertmanager/alertmanager.yml <<EOF
global:
  resolve_timeout: 5m
  smtp_smarthost: 'smtp.gmail.com:587'
  smtp_from: '$SMTP_MAIL'
  smtp_auth_username: '$SMTP_MAIL'
  smtp_auth_password: '$SMTP_PASS'
  smtp_require_tls: true
route:
  group_by: ['alertname', 'severity']
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h
  receiver: 'email-admin'
receivers:
  - name: 'email-admin'
    email_configs:
      - to: '$ALERT_MAIL'
        send_resolved: true
        headers:
          Subject: '[PACS-ALERT] {{ .GroupLabels.alertname }}'
EOF

# ============================================
# 10. GRAFANA CONFIG + PROVISIONING + DASHBOARD
# ============================================
echo "📝 Grafana config oluşturuluyor..."
cat > grafana/grafana.ini <<EOF
[paths]
data = /var/lib/grafana
logs = /var/log/grafana
plugins = /var/lib/grafana/plugins
provisioning = /etc/grafana/provisioning

[smtp]
enabled = true
host = smtp.gmail.com:587
user = $SMTP_MAIL
password = $SMTP_PASS
skip_verify = false
from_address = $SMTP_MAIL
from_name = PACS Grafana Alarm
EOF

echo "📝 Grafana datasource provisioning oluşturuluyor..."
cat > grafana/provisioning/datasources/prometheus.yml <<'EOF'
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
    editable: true
EOF

echo "📝 Grafana dashboard provisioning oluşturuluyor..."
cat > grafana/provisioning/dashboards/dashboards.yml <<'EOF'
apiVersion: 1
providers:
  - name: 'PACS Dashboards'
    orgId: 1
    folder: 'PACS Gateway'
    type: file
    disableDeletion: false
    updateIntervalSeconds: 30
    allowUiUpdates: true
    options:
      path: /etc/grafana/provisioning/dashboards
EOF

echo "📝 Hazır PACS Gateway dashboard'u yazılıyor..."
cat > grafana/provisioning/dashboards/pacs-gateway-dashboard.json <<'EOF'
{
  "title": "PACS Gateway Overview",
  "uid": "pacs-gateway-overview",
  "timezone": "browser",
  "schemaVersion": 39,
  "version": 1,
  "refresh": "30s",
  "time": { "from": "now-6h", "to": "now" },
  "panels": [
    {
      "id": 1,
      "title": "Servis Durumu (Up/Down)",
      "type": "stat",
      "gridPos": { "h": 6, "w": 8, "x": 0, "y": 0 },
      "targets": [
        { "expr": "up{job=\"rclone\"}", "legendFormat": "Rclone RC" },
        { "expr": "up{job=\"node-exporter\"}", "legendFormat": "Node Exporter" }
      ],
      "fieldConfig": {
        "defaults": {
          "mappings": [
            { "type": "value", "options": { "0": { "text": "DOWN", "color": "red" }, "1": { "text": "UP", "color": "green" } } }
          ],
          "thresholds": { "mode": "absolute", "steps": [ { "value": null, "color": "red" }, { "value": 1, "color": "green" } ] }
        }
      }
    },
    {
      "id": 2,
      "title": "Hot Storage Disk Kullanımı (%)",
      "type": "gauge",
      "gridPos": { "h": 6, "w": 8, "x": 8, "y": 0 },
      "targets": [
        { "expr": "100 - (node_filesystem_avail_bytes{mountpoint=\"/mnt/pacs-hot\"} / node_filesystem_size_bytes{mountpoint=\"/mnt/pacs-hot\"} * 100)", "legendFormat": "Dolu %" }
      ],
      "fieldConfig": {
        "defaults": {
          "unit": "percent",
          "max": 100,
          "min": 0,
          "thresholds": { "mode": "absolute", "steps": [ { "value": null, "color": "green" }, { "value": 80, "color": "yellow" }, { "value": 90, "color": "red" } ] }
        }
      }
    },
    {
      "id": 3,
      "title": "CPU Kullanımı (%)",
      "type": "timeseries",
      "gridPos": { "h": 6, "w": 8, "x": 16, "y": 0 },
      "targets": [
        { "expr": "100 - (avg by(instance) (rate(node_cpu_seconds_total{mode=\"idle\"}[5m])) * 100)", "legendFormat": "CPU %" }
      ],
      "fieldConfig": { "defaults": { "unit": "percent" } }
    },
    {
      "id": 4,
      "title": "Disk I/O (okuma/yazma bayt/sn)",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 6 },
      "targets": [
        { "expr": "rate(node_disk_read_bytes_total[5m])", "legendFormat": "Okuma - {{device}}" },
        { "expr": "rate(node_disk_written_bytes_total[5m])", "legendFormat": "Yazma - {{device}}" }
      ],
      "fieldConfig": { "defaults": { "unit": "Bps" } }
    },
    {
      "id": 5,
      "title": "Bellek Kullanımı",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 12, "x": 12, "y": 6 },
      "targets": [
        { "expr": "node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes", "legendFormat": "Kullanılan" },
        { "expr": "node_memory_MemAvailable_bytes", "legendFormat": "Kullanılabilir" }
      ],
      "fieldConfig": { "defaults": { "unit": "bytes" } }
    },
    {
      "id": 6,
      "title": "Ağ Trafiği (bayt/sn)",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 14 },
      "targets": [
        { "expr": "rate(node_network_receive_bytes_total{device!=\"lo\"}[5m])", "legendFormat": "Alınan - {{device}}" },
        { "expr": "rate(node_network_transmit_bytes_total{device!=\"lo\"}[5m])", "legendFormat": "Gönderilen - {{device}}" }
      ],
      "fieldConfig": { "defaults": { "unit": "Bps" } }
    },
    {
      "id": 7,
      "title": "Sistem Uptime",
      "type": "stat",
      "gridPos": { "h": 8, "w": 12, "x": 12, "y": 14 },
      "targets": [
        { "expr": "node_time_seconds - node_boot_time_seconds", "legendFormat": "Uptime" }
      ],
      "fieldConfig": { "defaults": { "unit": "s" } }
    }
  ]
}
EOF

# ============================================
# 11. DOCKER COMPOSE
# ============================================
echo "📝 Docker Compose dosyası oluşturuluyor..."
cat > docker-compose.yml <<'EOF'
services:
  node-exporter:
    image: prom/node-exporter:latest
    container_name: pacs-node-exporter
    restart: always
    volumes:
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /:/rootfs:ro
    command:
      - '--path.procfs=/host/proc'
      - '--path.sysfs=/host/sys'
      - '--collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|etc|rootfs/var/lib/docker/containers|rootfs/var/lib/docker/overlay2|rootfs/run/docker/netns|rootfs/var/lib/docker/aufs)($$|/)'
    ports:
      - "9100:9100"

  prometheus:
    image: prom/prometheus:latest
    container_name: pacs-prometheus
    restart: always
    ports:
      - "9090:9090"
    volumes:
      - ./prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - ./prometheus/alert.rules.yml:/etc/prometheus/alert.rules.yml:ro
      - prometheus_data:/prometheus
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.path=/prometheus'
    extra_hosts:
      - "host.docker.internal:host-gateway"

  alertmanager:
    image: prom/alertmanager:latest
    container_name: pacs-alertmanager
    restart: always
    ports:
      - "9393:9393"
    volumes:
      - ./alertmanager/alertmanager.yml:/etc/alertmanager/alertmanager.yml:ro
    command:
      - '--config.file=/etc/alertmanager/alertmanager.yml'
      - '--web.listen-address=:9393'

  grafana:
    image: grafana/grafana:latest
    container_name: pacs-grafana
    restart: always
    ports:
      - "3000:3000"
    volumes:
      - grafana_data:/var/lib/grafana
      - ./grafana/grafana.ini:/etc/grafana/grafana.ini:ro
      - ./grafana/provisioning:/etc/grafana/provisioning:ro
    environment:
      - GF_INSTALL_PLUGINS=grafana-piechart-panel
      - GF_AUTH_ANONYMOUS_ENABLED=false

volumes:
  prometheus_data:
  grafana_data:
EOF

# ============================================
# 12. SYSTEMD: RCLONE RC (metrics)
# ============================================
echo "📝 Rclone RC systemd servisi oluşturuluyor..."
cat > /etc/systemd/system/rclone-rcd.service <<EOF
[Unit]
Description=Rclone Remote Control Daemon
After=network-online.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/rclone rcd \
  --rc-addr=0.0.0.0:5572 \
  --rc-user=$RC_USER \
  --rc-pass=$RC_PASS \
  --rc-enable-metrics \
  --rc-web-gui
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable rclone-rcd
sudo systemctl restart rclone-rcd

# ============================================
# 13. SAMBA KULLANICISI OLUŞTUR
# ============================================
echo "👤 Samba kullanıcısı oluşturuluyor..."
sudo useradd -M -s /sbin/nologin "$SMB_USER" 2>/dev/null || true
echo -e "$SMB_PASS\n$SMB_PASS" | sudo smbpasswd -a -s "$SMB_USER"

SMB_UID=$(id -u "$SMB_USER")
SMB_GID=$(id -g "$SMB_USER")

sudo tee /etc/samba/smb.conf > /dev/null <<EOF
[global]
   server min protocol = SMB2
   server max protocol = SMB3
   client min protocol = SMB2
   client max protocol = SMB3
   workgroup = PACS
   interfaces = 0.0.0.0/0
   bind interfaces only = no

[PACS_Local]
   path = ${LOCAL_PATH}
   browseable = yes
   read only = no
   guest ok = no
   valid users = $SMB_USER
   force user = $SMB_USER
   force group = $SMB_USER
   create mask = 0666
   directory mask = 0777

[PACS_Archive]
   path = ${RO_MOUNT_PATH}
   browseable = yes
   read only = yes
   guest ok = no
   valid users = $SMB_USER
   force user = $SMB_USER
   force group = $SMB_USER
EOF

sudo systemctl enable smbd
sudo systemctl restart smbd

sudo chown -R "$SMB_USER:$SMB_USER" "$LOCAL_PATH"
sudo chmod -R 0775 "$LOCAL_PATH"

# ============================================
# 14. SYSTEMD: UPLOAD WATCHER
# ============================================
echo "📝 Upload watcher systemd servisi oluşturuluyor..."
sudo chmod +x /opt/pacs-gateway/scripts/upload-watcher.sh

cat > /etc/systemd/system/pacs-upload-watcher.service <<EOF
[Unit]
Description=PACS Upload Watcher (inotify close_write -> OBS)
After=network-online.target

[Service]
Type=simple
User=root
Environment=LOCAL_DIR=${LOCAL_PATH}
Environment=BUCKET_NAME=${BUCKET_NAME}
Environment=RCLONE_CONF=/etc/rclone/rclone.conf
Environment=LOG_FILE=/opt/pacs-gateway/logs/upload-watcher.log
Environment=STATE_DIR=/opt/pacs-gateway/state/uploaded
ExecStart=/opt/pacs-gateway/scripts/upload-watcher.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable pacs-upload-watcher
sudo systemctl restart pacs-upload-watcher

# ============================================
# 15. CRON: CLEANUP
# ============================================
echo "📝 Cleanup cron job'ı kuruluyor..."
sudo chmod +x /opt/pacs-gateway/scripts/cleanup-old.sh
sudo tee /etc/cron.d/pacs-cleanup > /dev/null <<EOF
*/10 * * * * root LOCAL_DIR=${LOCAL_PATH} STATE_DIR=/opt/pacs-gateway/state/uploaded LOG_FILE=/opt/pacs-gateway/logs/cleanup.log MAX_AGE_HOURS=${MAX_AGE_HOURS} /opt/pacs-gateway/scripts/cleanup-old.sh
EOF
sudo chmod 644 /etc/cron.d/pacs-cleanup

# ============================================
# 16. SYSTEMD: READ-ONLY RCLONE MOUNT (Doktor/Fuji erişimi) - DİNAMİK CACHE
# ============================================
echo "📝 Read-only rclone mount servisi oluşturuluyor (cache-first, dinamik cache: ${RO_CACHE_AGE} / ${RO_CACHE_SIZE})..."
cat > /etc/systemd/system/rclone-mount-obs-readonly.service <<EOF
[Unit]
Description=Rclone Mount OBS (READ-ONLY - Fuji/Doktor Erişimi)
After=network-online.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/rclone mount obs:${BUCKET_NAME} ${RO_MOUNT_PATH} \
  --config /etc/rclone/rclone.conf \
  --allow-other \
  --read-only \
  --uid ${SMB_UID} \
  --gid ${SMB_GID} \
  --dir-perms 0555 \
  --file-perms 0444 \
  --vfs-cache-mode full \
  --vfs-cache-max-age ${RO_CACHE_AGE} \
  --vfs-cache-max-size ${RO_CACHE_SIZE} \
  --vfs-read-chunk-size 128M \
  --vfs-read-chunk-size-limit 1G \
  --dir-cache-time 168h \
  --buffer-size 256M \
  --log-level INFO \
  --log-file /opt/pacs-gateway/logs/rclone-mount-ro.log
ExecStop=/bin/fusermount -uz ${RO_MOUNT_PATH}
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable rclone-mount-obs-readonly
sudo systemctl restart rclone-mount-obs-readonly

# ============================================
# 17. DOCKER COMPOSE BAŞLAT
# ============================================
echo "🐳 Docker Compose başlatılıyor..."
sudo docker compose up -d

# ============================================
# 18. KURULUM SONRASI KONTROLLER
# ============================================
echo ""
echo "🔍 Kurulum sonrası kontroller yapılıyor..."
sleep 3

if curl -s -u ${RC_USER}:${RC_PASS} http://localhost:5572/metrics > /dev/null 2>&1; then
    echo "✅ Rclone RC API çalışıyor."
else
    echo "❌ Rclone RC API çalışmıyor! sudo journalctl -u rclone-rcd -f"
fi

if sudo systemctl is-active --quiet pacs-upload-watcher; then
    echo "✅ Upload watcher çalışıyor."
else
    echo "❌ Upload watcher çalışmıyor! sudo journalctl -u pacs-upload-watcher -f"
fi

if mount | grep -q "$RO_MOUNT_PATH"; then
    echo "✅ Read-only OBS mount başarılı."
else
    echo "❌ Read-only mount başarısız! sudo journalctl -u rclone-mount-obs-readonly -f"
fi

if sudo systemctl is-active --quiet smbd; then
    echo "✅ Samba servisi çalışıyor."
else
    echo "❌ Samba servisi çalışmıyor! sudo journalctl -u smbd -f"
fi

for c in pacs-prometheus pacs-grafana pacs-alertmanager; do
    if docker ps | grep -q "$c"; then
        echo "✅ $c çalışıyor."
    else
        echo "❌ $c çalışmıyor! docker logs $c"
    fi
done

# ============================================
# 19. KURULUM TAMAMLANDI
# ============================================
echo ""
echo "=============================================="
echo "✅ Kurulum tamamlandı!"
echo "=============================================="
echo ""
echo "📌 Erişim Bilgileri:"
echo "   Private IP: $PRIVATE_IP"
echo "   Public IP: $PUBLIC_IP"
echo ""
echo "   📤 Fuji/PACS YAZMA paylaşımı: \\\\$PUBLIC_IP\\PACS_Local"
echo "   📥 Doktor OKUMA paylaşımı (read-only): \\\\$PUBLIC_IP\\PACS_Archive"
echo "   SMB Kullanıcı: $SMB_USER"
echo ""
echo "   Grafana: http://$PUBLIC_IP:3000 (admin/admin) - PACS Gateway dashboard hazır gelir"
echo "   Prometheus: http://$PUBLIC_IP:9090"
echo "   Rclone Web GUI: http://$PUBLIC_IP:5572 ($RC_USER/****)"
echo "   Alertmanager: http://$PUBLIC_IP:9393"
echo ""
echo "📋 Servis Yönetimi:"
echo "   sudo systemctl status pacs-upload-watcher rclone-mount-obs-readonly rclone-rcd smbd"
echo "   cd /opt/pacs-gateway && docker compose ps"
echo ""
echo "📁 Staging (yazılabilir): $LOCAL_PATH"
echo "📁 Arşiv (read-only, OBS cache-first): $RO_MOUNT_PATH"
echo "🕒 Yerelden silme eşiği: ${MAX_AGE_HOURS} saat (OBS'e yüklendikten sonra)"
echo "📦 Arşiv Cache: Süre=${RO_CACHE_AGE}, Max Boyut=${RO_CACHE_SIZE}"
echo ""
echo "📝 HATA KONTROLÜ (Loglar):"
echo "   Upload watcher: tail -f /opt/pacs-gateway/logs/upload-watcher.log"
echo "   Cleanup:        tail -f /opt/pacs-gateway/logs/cleanup.log"
echo "   RO mount:       sudo journalctl -u rclone-mount-obs-readonly -f"
echo "   Samba:          sudo journalctl -u smbd -f"
echo "=============================================="
echo "   ██████╗██╗      ██████╗ ██╗   ██╗███████╗"
echo "  ██╔════╝██║     ██╔═══██╗██║   ██║██╔════╝"
echo "  ██║     ██║     ██║   ██║██║   ██║███████╗"
echo "  ██║     ██║     ██║   ██║██║   ██║╚════██║"
echo "  ╚██████╗███████╗╚██████╔╝╚██████╔╝███████║"
echo "   ╚═════╝╚══════╝ ╚═════╝  ╚═════╝ ╚══════╝"
echo ""
echo "=============================================="
echo "   🚀 Developed by Furkan YIGIT | Cloud Solution Architect | Clous Cloud"
echo "=============================================="