# 🏥 PACS Gateway v2 - Staged Upload Architecture

Bu repo, hastane PACS verilerini **Huawei Cloud OBS**'ye taşıyan, **izlenebilir**, **alarmlı** bir gateway sisteminin kurulumunu otomatikleştirir.

**Önemli fark (v1 → v2):** OBS ile doğrudan `sync` YAPILMAZ (sync'te yerelde silinen dosya OBS'te de silinir — riskli). Bunun yerine **tek yönlü, olay bazlı upload** ve **ayrı read-only arşiv mount'u** kullanılır.

---

## 🏗️ Mimari

```
Fuji/PACS ──SMB (yazma)──> /mnt/pacs-hot/local/  (gerçek disk)
                                  │
                                  │ inotifywait (close_write)
                                  ▼
                          upload-watcher.sh ──rclone copyto──> OBS bucket
                                  │                                 │
                                  │ (marker: state/uploaded/*)      │
                                  ▼                                 │
                          cleanup-old.sh (3 saat sonra sil,         │
                          SADECE OBS'e taşınmış olanları)           │
                                                                     │
Doktorlar ──SMB (read-only)──> /mnt/pacs-hot/archive-ro/ ──rclone mount (RO, cache-first)──┘
```

**Akış mantığı:**
1. Fuji/PACS, Samba üzerinden **PACS_Local** paylaşımına yazar (gerçek yerel disk).
2. `upload-watcher.sh`, bu dizini `inotifywait` ile izler. Bir dosyanın yazımı **bitince** (`close_write` — kopyalama sırasında değil), dosyayı `rclone copyto` ile OBS'e **tek yönlü** kopyalar.
3. Aynı isimle çakışma varsa (dosya zaten OBS'te varsa): loglanır, üzerine yazılmaz, atlanır.
4. Başarılı yükleme sonrası bir "marker" dosyası bırakılır. `cleanup-old.sh` (cron ile periyodik) SADECE marker'ı olan ve belirlenen süreden (test: 3 saat) eski dosyaları yerelden siler.
5. Doktorlar, ayrı bir **read-only rclone mount** (`archive-ro`) üzerinden OBS'i okur. Bu mount `--vfs-cache-mode full` ile çalışır:
   - Dosya cache'de varsa → OBS'e hiç gidilmez, yerelden sunulur.
   - Cache'de yoksa → OBS'ten otomatik indirilir, cache'e yazılır, sunulur.
   - Doktor tarafında path ve davranış **her zaman aynıdır**, cache durumu şeffaftır.

---

## 📁 Klasör Yapısı

```
pacs-gateway/
├── config/
│   ├── rclone.conf                # OBS bağlantı bilgileri
│   └── smb.conf                   # PACS_Local (yazma) + PACS_Archive (read-only) paylaşımları
├── scripts/
│   ├── upload-watcher.sh          # inotify close_write -> rclone copyto
│   └── cleanup-old.sh             # marker bazlı, süresi dolan yerel dosyaları siler
├── systemd/
│   ├── pacs-upload-watcher.service
│   ├── rclone-mount-obs-readonly.service
│   └── rclone-rcd.service         # metrics/monitoring API
├── prometheus/
│   ├── prometheus.yml
│   └── alert.rules.yml
├── alertmanager/
│   └── alertmanager.yml
├── grafana/
│   └── grafana.ini
├── docker-compose.yml             # Prometheus, Grafana, Alertmanager, Node Exporter
├── deploy.sh                      # Tek komutla kurulum
└── README.md
```

---

## 📋 Gereksinimler

- Ubuntu 22.04 / 24.04
- Root/sudo erişimi
- Huawei Cloud OBS Access Key + Secret Key + bucket
- SMTP mail hesabı (alarm için)
- `inotify-tools` (deploy.sh otomatik kurar)

---

## 🚀 Kurulum

```bash
chmod +x deploy.sh
./deploy.sh
```

Script sırayla sorar: OBS bilgileri, bucket, Samba kullanıcı/şifre, SMTP bilgileri, staging/arşiv dizinleri, ve **yerelden silme eşiği** (test: `3h`, prod önerisi: `168h`/7 gün).

---

## ▶️ Servis Yönetimi

```bash
# Durum kontrolü
sudo systemctl status pacs-upload-watcher rclone-mount-obs-readonly rclone-rcd smbd

# Loglar
tail -f /opt/pacs-gateway/logs/upload-watcher.log
tail -f /opt/pacs-gateway/logs/cleanup.log
sudo journalctl -u rclone-mount-obs-readonly -f

# Docker (monitoring stack)
cd /opt/pacs-gateway && docker compose ps
docker compose logs -f
```

---

## 🌐 Erişim Noktaları

| Servis | URL / Bilgi |
|--------|-------------|
| SMB - Yazma (Fuji/PACS) | `\\<IP>\PACS_Local` |
| SMB - Okuma (Doktorlar, read-only) | `\\<IP>\PACS_Archive` |
| Grafana | `http://<IP>:3000` (admin/admin) |
| Prometheus | `http://<IP>:9090` |
| Rclone Web GUI | `http://<IP>:5572` |
| Alertmanager | `http://<IP>:9393` |

---

## ⚠️ Alarm Kuralları

| Alarm | Açıklama |
|-------|----------|
| RcloneServiceDown | Rclone RC (metrics) servisi çöktü |
| SambaServiceDown | Samba çalışmıyor |
| HotStorageDiskSpaceWarning | Staging disk %80 dolu |
| HotStorageDiskSpaceCritical | Staging disk %90 dolu — upload-watcher/cleanup'ı kontrol edin |

> Not: Upload olay bazlı (inotify) olduğu için sürekli "transfer" metriği yoktur; watcher/cleanup logları asıl izleme kaynağıdır.

---

## 🛠️ Sorun Giderme

**Dosya OBS'e yüklenmiyor:**
```bash
sudo systemctl status pacs-upload-watcher
tail -f /opt/pacs-gateway/logs/upload-watcher.log
```

**Doktor dosyayı göremiyor / eski görünüyor:**
```bash
sudo systemctl status rclone-mount-obs-readonly
# Cache'i manuel temizlemek gerekirse (nadiren):
# sudo systemctl restart rclone-mount-obs-readonly
```

**Dosya OBS'e yüklenmeden yerelden silinmiş mi diye şüpheleniyorsanız:**
```bash
ls /opt/pacs-gateway/state/uploaded/   # marker'lar - sadece başarılı yüklemeler burada
```

---

## 🗑️ Tamamen Kaldırma

```bash
sudo systemctl disable --now pacs-upload-watcher rclone-mount-obs-readonly rclone-rcd smbd
cd /opt/pacs-gateway && docker compose down -v
sudo rm -rf /opt/pacs-gateway /mnt/pacs-hot /etc/rclone
sudo rm -f /etc/cron.d/pacs-cleanup
```

---

## 📄 Lisans

MIT License
