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
        # Umgebungsvariablen haben Vorrang vor der Konfigurationsdatei.
        local overrides
        overrides="$(export -p | grep -E '^declare -x (APP_[A-Z_]+|PHP_VERSION|NODE_MIN|SEED_DEMO_DATA|KEEP_BACKUPS)=' || true)"
        # shellcheck disable=SC1091
        . /etc/recordloom/recordloom.conf
        eval "$overrides"
    fi
    APP_NAME="${APP_NAME:-recordLoom}"
    # recordLoom ist privat: Zugriff per SSH mit Deploy-Key (siehe README).
    APP_REPO="${APP_REPO:-git@github.com:leshaze/recordLoom.git}"
    # Privater SSH-Schlüssel ohne Passphrase (leer = automatisch suchen)
    APP_SSH_KEY="${APP_SSH_KEY:-}"
    APP_BRANCH="${APP_BRANCH:-main}"
    APP_DIR="${APP_DIR:-/var/www/recordLoom}"
    APP_TIMEZONE="${APP_TIMEZONE:-Europe/Berlin}"
    PHP_VERSION="${PHP_VERSION:-}"
    SEED_DEMO_DATA="${SEED_DEMO_DATA:-0}"
    APP_USER="${APP_USER:-www-data}"
    APP_HOME=/var/lib/recordloom
    BACKUP_DIR=/var/backups/recordloom
    KEEP_BACKUPS="${KEEP_BACKUPS:-14}"

    if [ "$(id -u)" -ne 0 ]; then
        echo "Bitte als root bzw. mit sudo ausführen." >&2
        exit 1
    fi
    # Befehle als www-data dürfen nicht im (für sie gesperrten) Verzeichnis
    # des Aufrufers starten, z.B. /root.
    cd /

    PHP_BIN="php${PHP_VERSION}"
    command -v "$PHP_BIN" >/dev/null || PHP_BIN=php
    PHP_FPM_SERVICE="$("$PHP_BIN" -r 'echo "php".PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION."-fpm";')"
    for tool in git composer npm sqlite3 runuser ssh; do
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

    # Bis zur Umstellung auf das private Repository stand hier die
    # HTTPS-Adresse, die ohne Anmeldung nicht mehr funktioniert.
    if [ "$APP_REPO" = "https://github.com/leshaze/recordLoom.git" ]; then
        APP_REPO="git@github.com:leshaze/recordLoom.git"
        info "Repository-Adresse auf SSH umgestellt: $APP_REPO"
        conf_set APP_REPO "$APP_REPO"
    fi
    setup_git_ssh

    # Zugriff prüfen. Gemergte Feature-Branches werden gelöscht - dann auf
    # main zurückfallen (aber nur, wenn das Repository erreichbar ist).
    local heads
    if ! heads="$(as_app git ls-remote --heads "$APP_REPO" 2>&1)"; then
        error "Kein Zugriff auf $APP_REPO:"
        local line
        while IFS= read -r line; do echo "      $line" >&2; done <<<"$heads"
        if [ -n "$APP_GIT_SSH" ]; then
            error "Ist der öffentliche Schlüssel ${SSH_KEY_SOURCE}.pub bei GitHub als Deploy-Key des Repositorys hinterlegt?"
        fi
        exit 1
    fi
    if [ "$APP_BRANCH" != main ] && ! grep -q "refs/heads/${APP_BRANCH}\$" <<<"$heads"; then
        warn "Branch $APP_BRANCH existiert nicht mehr - verwende main"
        APP_BRANCH=main
        conf_set APP_BRANCH main
    fi

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
    env_value APP_URL "${APP_URL:-https://${host}.local}" "$new_env"
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
    # Intervalle des Schedulers von recordLoom (Mail-Backup, Discogs-Preise)
    env_value BACKUP_INTERVAL_DAYS 1 "$new_env"
    env_value DISCOGS_NIGHTLY_PRICES false "$new_env"
    env_value DISCOGS_PRICE_INTERVAL_HOURS 24 "$new_env"
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

    step "Scheduler-Cronjob einrichten"
    # Läuft als Webserver-Benutzer, damit Caches und Logs nicht root gehören.
    if [ -d /etc/cron.d ]; then
        cat >/etc/cron.d/recordloom <<EOF
# Generiert von deployLaravel/deploy.sh - Laravel Scheduler von $APP_NAME
SHELL=/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
* * * * * $APP_USER cd $APP_DIR && $(command -v "$PHP_BIN") artisan schedule:run >> /dev/null 2>&1
EOF
        chmod 644 /etc/cron.d/recordloom
    else
        warn "/etc/cron.d fehlt (cron nicht installiert) - Scheduler nicht eingerichtet"
    fi

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

# SSH für Git einrichten, wenn das Repository per SSH angesprochen wird.
# www-data kann den Schlüssel von root nicht lesen, deshalb wird er mit
# eigener SSH-Konfiguration nach $APP_HOME/.ssh kopiert.
setup_git_ssh() {
    APP_GIT_SSH=""
    case "$APP_REPO" in
        git@* | ssh://*) ;;
        *) return 0 ;;
    esac
    SSH_KEY_SOURCE="$APP_SSH_KEY"
    if [ -z "$SSH_KEY_SOURCE" ]; then
        local candidate candidates=(/etc/recordloom/deploy_key /root/.ssh/id_ed25519 /root/.ssh/id_rsa)
        # Bei Aufruf mit sudo auch den Schlüssel des aufrufenden Benutzers.
        if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
            local sudo_home
            sudo_home="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
            if [ -n "$sudo_home" ]; then
                candidates+=("$sudo_home/.ssh/id_ed25519" "$sudo_home/.ssh/id_rsa")
            fi
        fi
        for candidate in "${candidates[@]}"; do
            if [ -f "$candidate" ]; then
                SSH_KEY_SOURCE="$candidate"
                break
            fi
        done
    fi
    if [ -z "$SSH_KEY_SOURCE" ] || [ ! -f "$SSH_KEY_SOURCE" ]; then
        error "Kein SSH-Schlüssel für $APP_REPO gefunden${APP_SSH_KEY:+ ($APP_SSH_KEY)}."
        error "Vorhandenen Schlüssel eintragen:  APP_SSH_KEY=\"/home/<user>/.ssh/id_ed25519\" in /etc/recordloom/recordloom.conf"
        error "oder neuen erzeugen:  ssh-keygen -t ed25519 -N '' -C recordloom-deploy -f /etc/recordloom/deploy_key"
        error "und /etc/recordloom/deploy_key.pub bei GitHub als Deploy-Key des Repositorys hinterlegen."
        exit 1
    fi
    local ssh_dir="$APP_HOME/.ssh"
    install -d -o "$APP_USER" -g "$APP_USER" -m 700 "$ssh_dir"
    install -o "$APP_USER" -g "$APP_USER" -m 600 "$SSH_KEY_SOURCE" "$ssh_dir/deploy_key"
    # Veröffentlichter Host-Schlüssel von GitHub; andere Hosts beim ersten
    # Kontakt übernehmen.
    if ! grep -q '^github.com ssh-ed25519 ' "$ssh_dir/known_hosts" 2>/dev/null; then
        echo "github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl" >>"$ssh_dir/known_hosts"
    fi
    chown "$APP_USER:$APP_USER" "$ssh_dir/known_hosts"
    chmod 644 "$ssh_dir/known_hosts"
    cat >"$ssh_dir/config" <<EOF
# Generiert von deployLaravel/deploy.sh
Host *
    IdentityFile $ssh_dir/deploy_key
    IdentitiesOnly yes
    UserKnownHostsFile $ssh_dir/known_hosts
    StrictHostKeyChecking accept-new
    BatchMode yes
EOF
    chown "$APP_USER:$APP_USER" "$ssh_dir/config"
    chmod 600 "$ssh_dir/config"
    APP_GIT_SSH="ssh -F $ssh_dir/config"
}

# conf_set KEY VALUE: Wert in /etc/recordloom/recordloom.conf setzen
conf_set() {
    local conf=/etc/recordloom/recordloom.conf
    [ -f "$conf" ] || return 0
    if grep -q "^$1=" "$conf"; then
        sed -i "s|^$1=.*|$1=\"$2\"|" "$conf"
    else
        echo "$1=\"$2\"" >>"$conf"
    fi
}

# Befehle als Webserver-Benutzer mit leerer, fester Umgebung ausführen (wie
# sudo, das aber in minimalen Containern fehlt) und mit beschreibbarem HOME
# für die Caches von Composer und npm. Puppeteer wird von recordLoom nicht mehr
# genutzt; der Chrome-Download würde auf ARM zudem fehlschlagen.
as_app() {
    runuser -u "$APP_USER" -- env -i \
        PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
        LANG=C.UTF-8 \
        HOME="$APP_HOME" \
        COMPOSER_HOME="$APP_HOME/composer" \
        npm_config_cache="$APP_HOME/npm" \
        PUPPETEER_SKIP_DOWNLOAD=true \
        ${APP_GIT_SSH:+GIT_SSH_COMMAND="$APP_GIT_SSH"} \
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
