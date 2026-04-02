#!/bin/bash
# =============================================================================
# Fedora Local Mirror Updater Script
# =============================================================================
# Description: Обновляет локальное зеркало репозиториев Fedora и RPM Fusion
# с понижением приоритета локальных репозиториев на время обновления.
# Version: 1.0.0
# License: MIT
# =============================================================================
set -euo pipefail

# Автоматически определяем версию Fedora
if [ -f /etc/os-release ]; then
    FEDORA_VERSION=$(source /etc/os-release && echo "$VERSION_ID")
else
    FEDORA_VERSION="43"
fi

MIRROR="/var/local/mirror"
LOG_FILE="/var/log/fedora-mirror-update.log"
LOCKFILE="/var/run/fedora-mirror.lock"
LOCAL_REPO_CONF="/etc/yum.repos.d/local-mirror.repo"

SYNC_ARCHS=("x86_64" "i686" "noarch")

REPOS=(
    "fedora"
    "updates"
    "fedora-cisco-openh264"
    "rpmfusion-free"
    "rpmfusion-free-updates"
    "rpmfusion-nonfree"
    "rpmfusion-nonfree-updates"
)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"; }
error() { echo -e "${RED}[ОШИБКА]${NC} $1" | tee -a "$LOG_FILE"; exit 1; }
warning() { echo -e "${YELLOW}[ПРЕДУПРЕЖДЕНИЕ]${NC} $1" | tee -a "$LOG_FILE"; }

acquire_lock() {
    if [ -e "$LOCKFILE" ] && kill -0 "$(cat "$LOCKFILE")" 2>/dev/null; then
        error "Процесс зеркалирования уже запущен (PID $(cat "$LOCKFILE"))"
    fi
    echo $$ > "$LOCKFILE"
    trap 'enable_local_repos; rm -f "$LOCKFILE"' EXIT INT TERM
}

disable_local_repos() {
    log "Временное отключение локального зеркала через DNF..."
    sudo dnf config-manager --set-disabled 'local-*' >/dev/null 2>&1 || true
    sudo dnf clean metadata >/dev/null 2>&1
}

enable_local_repos() {
    log "Включение локального зеркала..."
    sudo dnf config-manager --set-enabled 'local-*' >/dev/null 2>&1 || true
}

sync_repository() {
    local repo="$1"
    log "Синхронизация: $repo"
    local dir="$MIRROR/$repo"
    sudo mkdir -p "$dir"

    local archs=""
    for a in "${SYNC_ARCHS[@]}"; do archs="$archs --arch=$a"; done

    # Отключаем локальные репозитории для предотвращения конфликтов метаданных
    # В dnf5 --disablerepo нельзя использовать вместе с --repo.
    sudo dnf reposync \
        --repo="$repo" $archs \
        --newest-only --nogpgcheck --norepopath \
        --download-path="$dir" --delete --download-metadata \
        --remote-time \
        --setopt=max_parallel_downloads=20 \
        --setopt=deltarpm=False \
        2>&1 | tee -a "$LOG_FILE"

    log "Готово: $repo"
}

remove_old_versions() {
    log "Очистка старых версий..."
    for repo in "${REPOS[@]}"; do
        local dir="$MIRROR/$repo"
        [ -d "$dir" ] || continue

        if command -v repomanage >/dev/null; then
            sudo repomanage --keep=1 --nocheck "$dir" | xargs -r sudo rm -vf | tee -a "$LOG_FILE"
        else
            warning "repomanage отсутствует → ручная очистка"
            find "$dir" -name '*.rpm' -print0 | sort -zV | awk -v RS='\0' '
                match($0, /.*\/([^\/]+)-[0-9][^\/]*\.rpm$/, a) { name = a[1] }
                name == prev { print prevfile; prevfile = $0; next }
                name != prev { prev = name; prevfile = $0; next }
            ' | xargs -r0 sudo rm -vf | tee -a "$LOG_FILE"
        fi
    done
    log "Очистка завершена"
}

create_metadata() {
    local path="$1"
    log "Метаданные: $path"
    
    # Полностью пересоздаем метаданные для надежности
    sudo rm -rf "$path/repodata"

    local comp="gz"
    if createrepo_c --version 2>&1 | grep -qi zstd && command -v zstd >/dev/null; then
        comp="zstd"
    fi

    sudo createrepo_c --update --workers=auto --retain-old-md=0 --zchunk \
        --general-compress-type="$comp" --quiet "$path" 2>&1 | tee -a "$LOG_FILE"

    log "Метаданные готовы ($comp)"
}

update_cache() {
    log "Обновление кэша DNF..."
    sudo dnf clean all >/dev/null 2>&1
    sudo dnf makecache >/dev/null 2>&1
}

show_stats() {
    log "Статистика зеркала"
    local total=0 total_size

    for repo in "${REPOS[@]}"; do
        local p="$MIRROR/$repo"
        if [ -d "$p" ]; then
            local cnt=$(find "$p" -name '*.rpm' -type f 2>/dev/null | wc -l)
            local sz=$(du -sh "$p" 2>/dev/null | cut -f1)
            printf " %-30s %6s пакетов, %s\n" "$repo:" "$cnt" "$sz"
            total=$((total + cnt))
        else
            printf " %-30s не синхронизирован\n" "$repo:"
        fi
    done

    total_size=$(du -sh "$MIRROR" 2>/dev/null | cut -f1)
    log "Всего пакетов: $total"
    log "Общий размер: $total_size"
}

main() {
    [ "$EUID" -ne 0 ] && { echo -e "${RED}[ОШИБКА]${NC} sudo требуется"; exit 1; }

    log "========================================="
    log "Запуск обновления локального зеркала Fedora"
    log "========================================="

    acquire_lock

    # 1. Отключаем локальные зеркала перед запуском обновления в dnf
    disable_local_repos

    for r in "${REPOS[@]}"; do sync_repository "$r"; done

    remove_old_versions

    for r in "${REPOS[@]}"; do
        local p="$MIRROR/$r"
        [ -d "$p" ] && create_metadata "$p"
    done

    # 2. Включаем обратно после обновления всего
    enable_local_repos

    update_cache
    show_stats

    log "Готово! Локальное зеркало обновлено."
}

main
exit 0
