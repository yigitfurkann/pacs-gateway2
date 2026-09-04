#!/bin/bash
# upload-watcher.sh
# /mnt/pacs-hot/local dizinini izler. Bir dosyanın yazımı bitince (close_write)
# OBS'e tek yönlü olarak kopyalar (sync değil - kaynak asla silinmez/senkronlanmaz).
# Aynı isimle üzerine yazma çakışması varsa: LOGLAR, YÜKLEMEYİ ATLAR.

set -u

LOCAL_DIR="${LOCAL_DIR:-/mnt/pacs-hot/local}"
BUCKET_NAME="${BUCKET_NAME:-YOUR_BUCKET}"
RCLONE_CONF="${RCLONE_CONF:-/etc/rclone/rclone.conf}"
LOG_FILE="${LOG_FILE:-/opt/pacs-gateway/logs/upload-watcher.log}"
STATE_DIR="${STATE_DIR:-/opt/pacs-gateway/state/uploaded}"

mkdir -p "$STATE_DIR" "$(dirname "$LOG_FILE")"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"
}

log "🚀 Upload watcher başlatıldı: $LOCAL_DIR izleniyor -> obs:${BUCKET_NAME}"

inotifywait -m -r -e close_write --format '%w%f' "$LOCAL_DIR" | while read -r FILEPATH
do
    FILENAME=$(basename "$FILEPATH")
    case "$FILENAME" in
        .*|*.tmp|*.partial|~*)
            log "⏭️  Geçici dosya atlandı: $FILEPATH"
            continue
            ;;
    esac

    if [[ ! -f "$FILEPATH" ]]; then
        log "⚠️  Dosya bulunamadı (muhtemelen taşındı/silindi): $FILEPATH"
        continue
    fi

    RELATIVE_PATH="${FILEPATH#$LOCAL_DIR/}"
    REMOTE_PATH="obs:${BUCKET_NAME}/${RELATIVE_PATH}"
    MARKER_FILE="${STATE_DIR}/${RELATIVE_PATH//\//__}.uploaded"

    # --- ÇAKIŞMA KONTROLÜ: OBS'te zaten varsa üzerine yazma, atla ---
    # NOT: 'rclone lsf' tek bir dosya yoluna bakıldığında dosya bulunamasa
    # bile exit code 0 döner. Bu yüzden exit code değil, çıktının dolu
    # olup olmadığı kontrol edilir.
    EXISTING=$(rclone lsf "$REMOTE_PATH" --config "$RCLONE_CONF" 2>/dev/null)
    if [[ -n "$EXISTING" ]]; then
        log "⚠️  ÇAKIŞMA: $REMOTE_PATH zaten OBS'te mevcut. Yükleme ATLANDI."
        continue
    fi

    log "📤 Yükleniyor: $FILEPATH -> $REMOTE_PATH"

    if rclone copyto "$FILEPATH" "$REMOTE_PATH" \
        --config "$RCLONE_CONF" \
        --log-level INFO \
        --log-file "$LOG_FILE"; then

        mkdir -p "$(dirname "$MARKER_FILE")"
        date -u +"%Y-%m-%dT%H:%M:%SZ" > "$MARKER_FILE"
        log "✅ Yükleme tamamlandı: $RELATIVE_PATH"
    else
        log "❌ Yükleme BAŞARISIZ: $RELATIVE_PATH (marker oluşturulmadı, cleanup bu dosyayı SİLMEYECEK)"
    fi
done
