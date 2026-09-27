#!/usr/bin/env bash
#
# Installiert bzw. aktualisiert recordLoom. Wird von installer.sh als
# /usr/local/sbin/recordloom-deploy installiert und kann jederzeit erneut
# ausgeführt werden, um den aktuellen Stand aus Git einzuspielen:
#
#   sudo recordloom-deploy
#
# Einstellungen stehen in /etc/recordloom/recordloom.conf und können per
# Umgebungsvariable überschrieben werden.

main() {
    set -Eeuo pipefail
    exec </dev/null

    if [ -f /etc/recordloom/recordloom.conf ]; then
        # shellcheck disable=SC1091
        . /etc/recordloom/recordloom.conf
    fi
    APP_NAME="${APP_NAME:-recordLoom}"
    APP_REPO="${APP_REPO:-https://github.com/leshaze/recordLoom.git}"
    APP_BRANCH="${APP_BRANCH:-claude/upgrade-security-0h8wx0}"
    APP_DIR="${APP_DIR:-/var/www/recordLoom}"
    APP_TIMEZONE="${APP_TIMEZONE:-Europe/Berlin}"
    PHP_VERSION="${PHP_VERSION:-}"
    SEED_DEMO_DATA="${SEED_DEMO_DATA:-0}"
    APP_USER="${APP_USER:-www-data}"
    APP_HOME=/var/lib/recordloom
    BACKUP_DIR=/var/backups/recordloom
    KEEP_BACKUPS="${KEEP_BACKUPS:-14}"

    if [ "$(id -u)" -ne 0 ]; then
        echo "Bitte mit sudo ausführen." >&2
        exit 1
    fi

    PHP_BIN="php${PHP_VERSION}"
    command -v "$PHP_BIN" >/dev/null || PHP_BIN=php
    PHP_FPM_SERVICE="$("$PHP_BIN" -r 'echo "php".PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION."-fpm";')"
    for tool in git composer npm sqlite3; do
        command -v "$tool" >/dev/null || { error "$tool fehlt - bitte zuerst installer.sh ausführen"; exit 1; }
    done

    if ! dpkg --compare-versions "$(node -p 'process.versions.node')" ge "${NODE_MIN:-24}"; then
        warn "Node.js $(node -v) ist älter als ${NODE_MIN:-24} - bitte installer.sh erneut ausführen"
    fi

    install -d -o "$APP_USER" -g "$APP_USER" -m 750 "$APP_HOME"
    install -d -o root -g root -m 700 "$BACKUP_DIR"

    MAINTENANCE=0
    trap on_exit EXIT
    trap 'error "Abbruch in Zeile $LINENO (Befehl: $BASH_COMMAND)"' ERR

    step "Deployment von $APP_NAME ($APP_BRANCH) nach $APP_DIR"
    local fresh=0
    if [ ! -d "$APP_DIR/.git" ]; then
        fresh=1
        if [ -d "$APP_DIR" ] && [ -n "$(ls -A "$APP_DIR")" ]; then
            error "$APP_DIR existiert, ist aber kein Git-Repository"
            exit 1
        fi
        step "Repository klonen"
        install -d -o "$APP_USER" -g "$APP_USER" "$APP_DIR"
        as_app git clone --branch "$APP_BRANCH" "$APP_REPO" "$APP_DIR"
        cd "$APP_DIR"
    else
        cd "$APP_DIR"
        # Ältere Versionen dieses Skripts haben teilweise als root gearbeitet.
        chown -R "$APP_USER:$APP_USER" "$APP_DIR"
        if [ -f vendor/autoload.php ] && [ -f .env ]; then
            step "Wartungsmodus aktivieren"
            if as_app "$PHP_BIN" artisan down --retry=15; then
                MAINTENANCE=1
            else
                warn "artisan down fehlgeschlagen"
            fi
        fi
        step "Neuesten Stand holen"
        as_app git remote set-url origin "$APP_REPO"
        as_app git fetch --prune origin "$APP_BRANCH"
        # Lokale Änderungen am Code würden den Checkout blockieren. Sie werden
        # gesichert und verworfen, damit exakt der Stand aus Git läuft.
        if [ -n "$(as_app git status --porcelain --untracked-files=no)" ]; then
            local changes
            changes="$BACKUP_DIR/local-changes-$(date +%Y%m%d-%H%M%S).patch"
            as_app git diff HEAD >"$changes"
            chmod 600 "$changes"
            warn "Lokale Änderungen im Code werden verworfen (gesichert in $changes):"
            as_app git status --short --untracked-files=no | sed 's/^/      /'
        fi
        as_app git checkout --force -B "$APP_BRANCH" "origin/$APP_BRANCH"
        as_app git reset --hard "origin/$APP_BRANCH"
    fi
    info "Stand: $(as_app git log -1 --format='%h %s (%ci)')"

    step ".env prüfen"
    local new_env=0
    if [ ! -f .env ]; then
        new_env=1
        as_app cp .env.example .env
    fi
    # Bei einer neuen .env alles setzen, bei einer bestehenden nur fehlende
    # Werte ergänzen, damit eigene Anpassungen erhalten bleiben.
    local host
    host="$(hostname)"
    env_value APP_NAME "$APP_NAME" "$new_env"
    env_value APP_ENV production "$new_env"
    env_value APP_DEBUG false "$new_env"
    env_value APP_URL "https://${host}.local" "$new_env"
    env_value APP_TIMEZONE "$APP_TIMEZONE" "$new_env"
    env_value APP_LOCALE de "$new_env"
    env_value LOG_CHANNEL stack "$new_env"
    env_value LOG_STACK daily "$new_env"
    env_value LOG_DAILY_DAYS 14 "$new_env"
    env_value LOG_LEVEL warning "$new_env"
    env_value DB_CONNECTION sqlite "$new_env"
    env_value SESSION_DRIVER database "$new_env"
    env_value SESSION_SECURE_COOKIE true "$new_env"
    env_value CACHE_STORE database "$new_env"
    env_value QUEUE_CONNECTION sync "$new_env"
    env_value FILESYSTEM_DISK local "$new_env"
    env_value BROADCAST_CONNECTION log "$new_env"
    chown "$APP_USER:$APP_USER" .env
    chmod 640 .env

    if [ ! -f database/database.sqlite ]; then
        as_app touch database/database.sqlite
    fi

    step "Composer-Abhängigkeiten installieren"
    as_app composer install --no-dev --optimize-autoloader --no-interaction --no-progress

    if ! grep -q '^APP_KEY=base64:' .env; then
        step "APP_KEY erzeugen"
        as_app "$PHP_BIN" artisan key:generate --force
    fi

    step "Frontend bauen (npm ci + vite build)"
    as_app npm ci --no-audit --no-fund
    as_app npm run build

    if [ -s database/database.sqlite ]; then
        step "Datenbank sichern"
        local backup
        backup="$BACKUP_DIR/database-$(date +%Y%m%d-%H%M%S).sqlite"
        sqlite3 database/database.sqlite ".backup '$backup'"
        chmod 600 "$backup"
        info "Sicherung: $backup"
        find "$BACKUP_DIR" -maxdepth 1 -name 'database-*.sqlite' -printf '%T@ %p\n' |
            sort -rn | tail -n +"$((KEEP_BACKUPS + 1))" | cut -d' ' -f2- | xargs -r rm -f
    fi

    step "Datenbank migrieren"
    as_app "$PHP_BIN" artisan migrate --force
    if [ "$fresh" = "1" ] && [ "$SEED_DEMO_DATA" = "1" ]; then
        step "Demodaten einspielen"
        as_app "$PHP_BIN" artisan db:seed --force
    fi

    if [ ! -L public/storage ]; then
        as_app "$PHP_BIN" artisan storage:link
    fi

    step "Caches aufbauen"
    as_app "$PHP_BIN" artisan optimize:clear
    if ! as_app "$PHP_BIN" artisan optimize; then
        warn "artisan optimize fehlgeschlagen - Routen werden nicht gecacht"
        as_app "$PHP_BIN" artisan optimize:clear
        as_app "$PHP_BIN" artisan config:cache
        as_app "$PHP_BIN" artisan view:cache
    fi

    step "Berechtigungen setzen"
    chown -R "$APP_USER:$APP_USER" "$APP_DIR"
    chmod -R ug+rwX storage bootstrap/cache database

    if systemctl list-unit-files "$PHP_FPM_SERVICE.service" >/dev/null 2>&1; then
        systemctl reload "$PHP_FPM_SERVICE" || systemctl restart "$PHP_FPM_SERVICE"
    fi

    if [ "$MAINTENANCE" = "1" ]; then
        as_app "$PHP_BIN" artisan up
        MAINTENANCE=0
    fi

    trap - ERR
    if command -v curl >/dev/null && systemctl is-active --quiet nginx 2>/dev/null; then
        if curl -skf -o /dev/null https://localhost/up; then
            step "Healthcheck OK - Deployment abgeschlossen"
        else
            warn "Healthcheck https://localhost/up fehlgeschlagen - siehe $APP_DIR/storage/logs"
            exit 1
        fi
    else
        step "Deployment abgeschlossen"
    fi
}

# Befehle als Webserver-Benutzer ausführen, mit beschreibbarem HOME für die
# Caches von Composer und npm. Puppeteer wird von recordLoom nicht mehr
# genutzt; der Chrome-Download würde auf ARM zudem fehlschlagen.
as_app() {
    sudo -u "$APP_USER" env \
        HOME="$APP_HOME" \
        COMPOSER_HOME="$APP_HOME/composer" \
        npm_config_cache="$APP_HOME/npm" \
        PUPPETEER_SKIP_DOWNLOAD=true \
        "$@"
}

# env_value KEY VALUE FORCE: setzt KEY in .env (FORCE=1) oder ergänzt ihn nur,
# wenn er fehlt (FORCE=0).
env_value() {
    local key="$1" value="$2" force="$3"
    if grep -q "^${key}=" .env; then
        if [ "$force" = "1" ]; then
            sed -i "s|^${key}=.*|${key}=${value}|" .env
        fi
    elif grep -q "^# *${key}=" .env; then
        sed -i "s|^# *${key}=.*|${key}=${value}|" .env
    else
        echo "${key}=${value}" >>.env
    fi
}

on_exit() {
    local rc=$?
    if [ "${MAINTENANCE:-0}" = "1" ]; then
        # Bei einem Fehler nicht im Wartungsmodus hängen bleiben.
        as_app "$PHP_BIN" artisan up || true
    fi
    if [ "$rc" -ne 0 ]; then
        error "Deployment fehlgeschlagen (Exit-Code $rc)"
    fi
}

step() { echo -e "\n\e[96m==> $*\e[0m"; }
info() { echo -e "\e[90m    $*\e[0m"; }
warn() { echo -e "\e[93m    WARNUNG: $*\e[0m"; }
error() { echo -e "\e[91mFEHLER: $*\e[0m" >&2; }

main "$@"
