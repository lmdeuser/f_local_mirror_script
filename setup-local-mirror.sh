#!/bin/bash
# =============================================================================
# Fedora Local Mirror Setup Script
# =============================================================================
# Description: Создаёт локальное зеркало репозиториев Fedora и RPM Fusion
# Author: Volkov Dmitriy
# Version: 1.2.6
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
LOG_FILE="/var/log/fedora-mirror-setup.log"
MIN_SPACE_GB=150
LOCKFILE="/var/run/fedora-mirror.lock"

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
    trap 'rm -f "$LOCKFILE"' EXIT INT TERM
}

install_prerequisites() {
    log "Установка необходимых пакетов..."
    sudo dnf install -y --assumeyes createrepo_c yum-utils dnf-utils zstd
}

ensure_rpmfusion() {
    log "Проверка RPM Fusion..."
    local free="/etc/yum.repos.d/rpmfusion-free.repo"
    local nonfree="/etc/yum.repos.d/rpmfusion-nonfree.repo"
    if [ -f "$free" ] && [ -f "$nonfree" ]; then
        log "RPM Fusion уже установлен ✓"
        return 0
    fi
    warning "Установка RPM Fusion..."
    sudo dnf install -y --assumeyes \
        "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm" \
        "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm"
    [ -f "$free" ] && [ -f "$nonfree" ] || error "Не удалось установить RPM Fusion"
}

enable_all_repositories() {
    log "Включение репозиториев..."
    for repo in "${REPOS[@]}"; do
        sudo dnf config-manager --set-enabled "$repo" 2>/dev/null || true
    done
    log "✓ Репозитории включены"
}

check_disk_space() {
    log "Проверка места..."
    local req=$MIN_SPACE_GB
    if [[ " ${SYNC_ARCHS[*]} " =~ " i686 " ]]; then req=200; log "i686 → требуем $req GiB"; fi

    local path="$MIRROR"
    [ -d "$path" ] || path=$(dirname "$path")
    local avail=$(df -BG "$path" | tail -1 | awk '{print $4}' | tr -d 'G')

    [ -z "$avail" ] && error "Не удалось проверить место"
    (( avail < req )) && error "Мало места: нужно ≥ ${req} GiB, есть ${avail}"
    log "✓ Доступно ${avail} GiB"
}

sync_repository() {
    local repo="$1"
    log "Синхронизация: $repo"

    local dir="$MIRROR/$repo"
    sudo mkdir -p "$dir"

    local archs=""
    for a in "${SYNC_ARCHS[@]}"; do archs="$archs --arch=$a"; done

    # Отключаем локальные репозитории, чтобы dnf не пытался синхронизироваться сам с собой
    sudo dnf reposync \
        --repo="$repo" $archs \
        --newest-only --nogpgcheck --norepopath \
        --download-path="$dir" --delete --download-metadata \
        --remote-time \
        --disablerepo='local-*' \
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

    # Удаляем старые данные перед запуском, если они есть
    sudo rm -rf "$path/repodata"

    local comp="gz"
    # Проверка поддержки zstd в createrepo_c
    if createrepo_c --version 2>&1 | grep -qi zstd && command -v zstd >/dev/null; then
        comp="zstd"
    fi

    # Используем zchunk и параллелизацию
    sudo createrepo_c --update --workers=auto --retain-old-md=0 --zchunk \
        --general-compress-type="$comp" --quiet "$path" 2>&1 | tee -a "$LOG_FILE"

    log "Метаданные готовы ($comp)"
}

create_local_repo_config() {
    log "Создание /etc/yum.repos.d/local-mirror.repo..."

    sudo tee /etc/yum.repos.d/local-mirror.repo >/dev/null <<EOF
# Локальное зеркало Fedora + RPM Fusion
# Создано: $(date)
# Путь: ${MIRROR}
EOF

    for repo in "${REPOS[@]}"; do
        local name="${repo}"
        case "$repo" in
            fedora) name="Fedora ${FEDORA_VERSION}" ;;
            updates) name="Fedora ${FEDORA_VERSION} Updates" ;;
            fedora-cisco-openh264) name="Cisco OpenH264" ;;
            rpmfusion-free) name="RPM Fusion Free" ;;
            rpmfusion-free-updates) name="RPM Fusion Free Updates" ;;
            rpmfusion-nonfree) name="RPM Fusion Nonfree" ;;
            rpmfusion-nonfree-updates) name="RPM Fusion Nonfree Updates" ;;
        esac

        sudo tee -a /etc/yum.repos.d/local-mirror.repo >/dev/null <<EOF
[local-$repo]
name=$name - Local Mirror (latest only)
baseurl=file://${MIRROR}/$repo
enabled=1
gpgcheck=0
priority=5
skip_if_unavailable=True
metadata_expire=never
cost=1000
EOF
    done

    log "Конфигурация создана"
}

update_cache() {
    log "Обновление кэша..."
    sudo dnf clean all
    sudo dnf makecache
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

    # остальная статистика (архитектуры, repodata, диск) — как было
    # ... (можно оставить твой код)
}

main() {
    [ "$EUID" -ne 0 ] && { echo -e "\033[0;31m[ОШИБКА]\033[0m sudo требуется"; exit 1; }

    log "========================================="
    log "Запуск зеркалирования Fedora $FEDORA_VERSION"
    log "========================================="

    acquire_lock

    install_prerequisites
    ensure_rpmfusion
    enable_all_repositories
    check_disk_space

    for r in "${REPOS[@]}"; do sync_repository "$r"; done

    remove_old_versions

    for r in "${REPOS[@]}"; do
        local p="$MIRROR/$r"
        [ -d "$p" ] && create_metadata "$p"
    done

    create_local_repo_config
    update_cache
    show_stats

    log "Готово! Локальное зеркало в $MIRROR"
}

main
exit 0

