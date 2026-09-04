#!/bin/bash
# cleanup-old.sh
# Sadece marker'ı olan (OBS'e başarıyla yüklenmiş) VE marker yaşı eşiği
# aşan yerel dosyaları siler. Cron ile periyodik çalışır.

set -u

LOCAL_DIR="${LOCAL_DIR:-/mnt/pacs-hot/local}"
STATE_DIR="${STATE_DIR:-/opt/pacs-gateway/state/uploaded}"
LOG_FILE="${LOG_FILE:-/opt/pacs-gateway/logs/cleanup.log}"

# TEST SENARYOSU: 3 saat. Prod'a geçerken büyütün (örn. 168 = 7 gün).
MAX_AGE_HOURS="${MAX_AGE_HOURS:-3}"

mkdir -p "$(dirname "$LOG_FILE")"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"
}

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
