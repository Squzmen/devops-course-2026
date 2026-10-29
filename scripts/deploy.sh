#!/usr/bin/env bash
# Доставка статического ресурса на devops-vm
# Использование: scripts/deploy.sh [--dry-run]
set -euo pipefail

REMOTE="devops"                     # псевдоним из ~/.ssh/config (ПР № 5, шаг 1.6)
REMOTE_DIR="/var/www/devops-site"
SITE_URL="https://devops.local"
CA_CERT="${HOME}/devops.crt"
LOCAL_DIR="$(git rev-parse --show-toplevel)/site/"

err() { echo "deploy: $*" >&2; }

# 1. Разбор аргумента --dry-run
DRY_RUN=""
case "${1:-}" in
    "")        ;;
    --dry-run) DRY_RUN="--dry-run" ;;
    *)         err "неизвестный аргумент '$1'; использование: $0 [--dry-run]"; exit 2 ;;
esac

# 2. Проверки по требованиям 4 и 5
if [[ ! -f "${LOCAL_DIR}index.html" ]]; then
    err "файл ${LOCAL_DIR}index.html отсутствует, доставка отменена"
    exit 1
fi
if [[ -n "$(git status --porcelain)" ]]; then
    err "в репозитории есть незафиксированные изменения, доставка отменена:"
    git status --short >&2
    exit 1
fi
COMMIT="$(git rev-parse --short HEAD)"

# 3. Синхронизация каталога ${LOCAL_DIR} на ${REMOTE}:${REMOTE_DIR}
#    одно SSH-соединение; BatchMode исключает интерактивный запрос пароля
rsync -avz --delete --chmod=D755,F644 ${DRY_RUN} \
    -e "ssh -o BatchMode=yes -o ConnectTimeout=5" \
    "${LOCAL_DIR}" "${REMOTE}:${REMOTE_DIR}/"

# 4. При --dry-run — завершение с кодом 0 без проверки доступности
if [[ -n "$DRY_RUN" ]]; then
    echo "deploy: пробный запуск завершён, состояние сервера не изменено (коммит ${COMMIT})"
    exit 0
fi

# 5. Проверка доступности ${SITE_URL} и завершение с корректным кодом возврата
if ! curl -fsS --cacert "$CA_CERT" -o /dev/null --max-time 10 "$SITE_URL/"; then
    err "ресурс ${SITE_URL} недоступен после доставки"
    exit 1
fi
echo "deploy: доставлен коммит ${COMMIT}, ресурс ${SITE_URL} доступен"
