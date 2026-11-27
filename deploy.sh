#!/usr/bin/env bash
#
# Installiert bzw. aktualisiert recordLoom. Wird von installer.sh als
# /usr/local/sbin/recordloom-deploy installiert und kann jederzeit erneut
# ausgeführt werden, um den aktuellen Stand aus Git einzuspielen:
#
#   sudo recordloom-deploy            # nur wenn sich etwas geändert hat
#   sudo recordloom-deploy --force    # immer neu bauen
#   sudo recordloom-deploy --no-mail-backup   # ohne Mail-Backup vorab
#
# Einstellungen stehen in /etc/recordloom/recordloom.conf und können per
# Umgebungsvariable überschrieben werden.
#
# Sicherheitsmodell: Die App gehört www-data, einem Konto, das bei einer
# Lücke in der Web-App als kompromittiert gelten muss. root fasst deshalb im
# App-Verzeichnis nichts an, was www-data durch einen Symlink umlenken
# könnte: Alle Schreibzugriffe dort laufen über as_app als www-data.

CONF_FILE=/etc/recordloom/recordloom.conf
STATE_FILE=/etc/recordloom/last-deploy
LOG_FILE=/var/log/recordloom-deploy.log

main() {
    set -Eeuo pipefail
    exec </dev/null

    local force=0 skip_mail_backup=0 arg
    for arg in "$@"; do
        case "$arg" in
            -f | --force) force=1 ;;
            --no-mail-backup) skip_mail_backup=1 ;;
            -h | --help)
                echo "Aufruf: recordloom-deploy [--force] [--no-mail-backup]"
                echo "  --force           auch dann neu bauen, wenn sich nichts geändert hat"
                echo "  --no-mail-backup  die Datenbank vor dem Update nicht per Mail verschicken"
                exit 0
                ;;
            *)
                echo "Unbekannte Option: $arg (siehe --help)" >&2
                exit 2
                ;;
        esac
    done

    if [ "$(id -u)" -ne 0 ]; then
        echo "Bitte als root bzw. mit sudo ausführen." >&2
        exit 1
    fi
    # Befehle als www-data dürfen nicht im (für sie gesperrten) Verzeichnis
    # des Aufrufers starten, z.B. /root.
    cd /

    load_conf
    APP_NAME="${APP_NAME:-recordLoom}"
    # recordLoom ist privat: Zugriff per SSH mit Deploy-Key (siehe README).
    APP_REPO="${APP_REPO:-git@github.com:leshaze/recordLoom.git}"
    # Privater SSH-Schlüssel ohne Passphrase (leer = automatisch suchen)
    APP_SSH_KEY="${APP_SSH_KEY:-}"
    APP_BRANCH="${APP_BRANCH:-main}"
    APP_DIR="${APP_DIR:-/var/www/recordLoom}"
    APP_URL="${APP_URL:-}"
    APP_TIMEZONE="${APP_TIMEZONE:-Europe/Berlin}"
    PHP_VERSION="${PHP_VERSION:-}"
    NODE_MIN="${NODE_MIN:-24}"
    SEED_DEMO_DATA="${SEED_DEMO_DATA:-0}"
    KEEP_BACKUPS="${KEEP_BACKUPS:-14}"
    # 1 = vor jedem Update die Datenbank per Mail verschicken (backup:mail von
    # recordLoom); das Update läuft nur weiter, wenn die Mail raus ist.
    MAIL_BACKUP_BEFORE_DEPLOY="${MAIL_BACKUP_BEFORE_DEPLOY:-1}"
    APP_USER="${APP_USER:-www-data}"
    APP_HOME=/var/lib/recordloom
    BACKUP_DIR=/var/backups/recordloom
    validate_settings
    APP_GROUP="$(id -gn "$APP_USER")"

    # Nur ein Deployment gleichzeitig.
    exec 9>/run/lock/recordloom-deploy.lock
    if ! flock -n 9; then
        echo "Es läuft bereits ein Deployment." >&2
        exit 1
    fi

    touch "$LOG_FILE"
    chmod 640 "$LOG_FILE"
    exec > >(tee -a "$LOG_FILE") 2>&1
    echo "===== $(date '+%F %T') recordloom-deploy $* ====="

    PHP_BIN="php${PHP_VERSION}"
    command -v "$PHP_BIN" >/dev/null || PHP_BIN=php
    for tool in git composer npm node sqlite3 runuser ssh "$PHP_BIN"; do
        command -v "$tool" >/dev/null || { error "$tool fehlt - bitte zuerst installer.sh ausführen"; exit 1; }
    done
    PHP_FPM_SERVICE="$("$PHP_BIN" -r 'echo "php".PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION."-fpm";')"

    if ! dpkg --compare-versions "$(node -p 'process.versions.node')" ge "$NODE_MIN"; then
        warn "Node.js $(node -v) ist älter als $NODE_MIN - bitte installer.sh erneut ausführen"
    fi

    install -d -o "$APP_USER" -g "$APP_GROUP" -m 750 "$APP_HOME"
    install -d -o root -g root -m 700 "$BACKUP_DIR"

    MAINTENANCE=0
    SSH_TMP=""
    APP_GIT_SSH=""
    trap on_exit EXIT
    trap 'exit 130' INT TERM HUP
    trap 'on_error "$LINENO" "${BASH_LINENO[0]}" "${FUNCNAME[0]}" "$BASH_COMMAND"' ERR

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
    local heads line
    if ! heads="$(as_app git ls-remote --heads "$APP_REPO" 2>&1)"; then
        error "Kein Zugriff auf $APP_REPO:"
        while IFS= read -r line; do echo "      $line" >&2; done <<<"$heads"
        if [ -n "$APP_GIT_SSH" ]; then
            error "Ist der öffentliche Schlüssel ${SSH_KEY_SOURCE}.pub bei GitHub als Deploy-Key des Repositorys hinterlegt?"
        fi
        exit 1
    fi
    if [ "$APP_BRANCH" != main ] &&
        ! awk -v ref="refs/heads/$APP_BRANCH" '$2 == ref { found = 1 } END { exit !found }' <<<"$heads"; then
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
        install -d -o "$APP_USER" -g "$APP_GROUP" -m 755 "$APP_DIR"
        as_app git clone --branch "$APP_BRANCH" "$APP_REPO" "$APP_DIR"
        cd "$APP_DIR"
    else
        cd "$APP_DIR"
        # Ältere Versionen dieses Skripts haben teilweise als root gearbeitet.
        # (chown -R folgt keinen Symlinks.)
        if [ -n "$(find "$APP_DIR" \( ! -user "$APP_USER" -o ! -group "$APP_GROUP" \) -print -quit)" ]; then
            info "Besitzer der App-Dateien wird auf $APP_USER korrigiert"
            chown -R "$APP_USER:$APP_GROUP" "$APP_DIR"
        fi
        step "Neuesten Stand holen"
        as_app git remote set-url origin "$APP_REPO"
        as_app git fetch --prune origin "+refs/heads/$APP_BRANCH:refs/remotes/origin/$APP_BRANCH"

        # Nichts zu tun, wenn seit dem letzten erfolgreichen Lauf weder Code
        # noch Einstellungen, .env, PHP oder Node.js geändert wurden.
        if [ "$force" = "0" ] && [ -f "$STATE_FILE" ] &&
            [ -z "$(as_app git status --porcelain --untracked-files=no)" ] &&
            [ "$(as_app git rev-parse HEAD)" = "$(as_app git rev-parse "origin/$APP_BRANCH")" ] &&
            [ "$(cat "$STATE_FILE")" = "$(deploy_signature)" ]; then
            trap - ERR
            info "Stand: $(as_app git log -1 --format='%h %s (%ci)')"
            # Der Cronjob wird auch ohne Update geprüft und bei Bedarf neu
            # geschrieben, damit der Scheduler nicht unbemerkt stillsteht.
            setup_cron
            step "Bereits aktuell - nichts zu tun (neu bauen mit: recordloom-deploy --force)"
            exit 0
        fi

        if [ -f vendor/autoload.php ] && [ -f .env ]; then
            step "Wartungsmodus aktivieren"
            if as_app "$PHP_BIN" artisan down --retry=15; then
                MAINTENANCE=1
            else
                warn "artisan down fehlgeschlagen"
            fi
        fi
        # Noch mit dem alten Code und vor jeder Änderung: Schlägt der Versand
        # fehl, bricht das Deployment ab und die App läuft unverändert weiter.
        if [ "$skip_mail_backup" = "1" ]; then
            warn "Mail-Backup vor dem Update übersprungen (--no-mail-backup)"
        elif [ "$MAIL_BACKUP_BEFORE_DEPLOY" = "1" ]; then
            mail_backup
        fi
        # Lokale Änderungen am Code würden den Checkout blockieren. Sie werden
        # gesichert und verworfen, damit exakt der Stand aus Git läuft.
        if [ -n "$(as_app git status --porcelain --untracked-files=no)" ]; then
            local changes
            changes="$BACKUP_DIR/local-changes-$(date +%Y%m%d-%H%M%S).patch"
            as_app git diff HEAD >"$changes"
            chmod 600 "$changes"
            warn "Lokale Änderungen im Code werden verworfen (gesichert in $changes):"
            as_app git status --short --untracked-files=no | sed 's/^/      /'
            prune_backups 'local-changes-*.patch'
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
    as_app chmod 640 .env
    # Bei einer neuen .env alles setzen, bei einer bestehenden nur fehlende
    # Werte ergänzen, damit eigene Anpassungen erhalten bleiben.
    env_value APP_NAME "$APP_NAME" "$new_env"
    env_value APP_ENV production "$new_env"
    env_value APP_DEBUG false "$new_env"
    env_value APP_URL "${APP_URL:-https://$(hostname).local}" "$new_env"
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
    # Mails von Benachrichtigungen warten in der Datenbank-Warteschlange; der
    # Scheduler von recordLoom arbeitet sie jede Minute ab.
    env_value QUEUE_CONNECTION database "$new_env"
    env_value FILESYSTEM_DISK local "$new_env"
    env_value BROADCAST_CONNECTION log "$new_env"
    # Intervalle des Schedulers von recordLoom (Mail-Backup, Discogs-Preise)
    env_value BACKUP_INTERVAL_DAYS 1 "$new_env"
    env_value DISCOGS_NIGHTLY_PRICES false "$new_env"
    env_value DISCOGS_PRICE_INTERVAL_HOURS 24 "$new_env"

    if [ ! -f database/database.sqlite ]; then
        as_app touch database/database.sqlite
    fi

    step "Composer-Abhängigkeiten installieren"
    as_app composer install --no-dev --optimize-autoloader --no-interaction --no-progress

    if ! as_app grep -q '^APP_KEY=base64:' .env; then
        step "APP_KEY erzeugen"
        as_app "$PHP_BIN" artisan key:generate --force
    fi

    step "Frontend bauen"
    # npm ci löscht node_modules und installiert alles neu - das dauert und
    # ist nur nötig, wenn sich package-lock.json oder Node.js geändert hat.
    local lock_sig
    lock_sig="$(as_app sha256sum package-lock.json | cut -d' ' -f1) $(node -v)"
    if [ -d node_modules ] && [ "$(as_app cat node_modules/.recordloom-lock 2>/dev/null || true)" = "$lock_sig" ]; then
        info "package-lock.json unverändert - npm ci übersprungen"
    else
        as_app npm ci --no-audit --no-fund
        printf '%s\n' "$lock_sig" | as_app tee node_modules/.recordloom-lock >/dev/null
    fi
    as_app npm run build

    if [ -s database/database.sqlite ]; then
        step "Datenbank sichern"
        # sqlite3 läuft als www-data (liest eine Datei, die www-data gehört);
        # root übernimmt nur das Ergebnis in das geschützte Verzeichnis.
        local backup tmp_backup
        backup="$BACKUP_DIR/database-$(date +%Y%m%d-%H%M%S).sqlite"
        tmp_backup="$APP_HOME/backup-$$.sqlite"
        as_app rm -f "$tmp_backup"
        as_app sqlite3 database/database.sqlite ".backup '$tmp_backup'"
        if [ -L "$tmp_backup" ] || [ ! -f "$tmp_backup" ]; then
            error "Sicherung der Datenbank fehlgeschlagen"
            exit 1
        fi
        install -o root -g root -m 600 "$tmp_backup" "$backup"
        as_app rm -f "$tmp_backup"
        info "Sicherung: $backup"
        prune_backups 'database-*.sqlite'
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
    # Datenbank, Uploads, Logs und .env sind für andere Benutzer des Systems
    # nicht lesbar.
    as_app chmod -R u+rwX,g+rwX,o-rwx storage bootstrap/cache database
    as_app chmod 640 .env

    setup_cron

    if systemctl list-unit-files "$PHP_FPM_SERVICE.service" >/dev/null 2>&1; then
        systemctl reload "$PHP_FPM_SERVICE" || systemctl restart "$PHP_FPM_SERVICE"
    fi

    if [ "$MAINTENANCE" = "1" ]; then
        as_app "$PHP_BIN" artisan up
        MAINTENANCE=0
    fi

    local mail_problem
    if [ "$MAIL_BACKUP_BEFORE_DEPLOY" = "1" ] && mail_problem="$(mail_backup_problem)"; then
        warn "$mail_problem."
        warn "Vor jedem Update wird die Datenbank per Mail verschickt - bis das eingerichtet ist,"
        warn "bricht das nächste Update ab (siehe README: Mail-Backup einrichten)."
    fi

    trap - ERR
    if command -v curl >/dev/null && systemctl is-active --quiet nginx 2>/dev/null; then
        # PHP-FPM braucht nach dem Neuladen einen Moment.
        local ok=0
        for _ in 1 2 3 4 5; do
            if curl -skf -o /dev/null --max-time 10 https://localhost/up; then
                ok=1
                break
            fi
            sleep 2
        done
        if [ "$ok" = "0" ]; then
            warn "Healthcheck https://localhost/up fehlgeschlagen - siehe $APP_DIR/storage/logs"
            exit 1
        fi
        deploy_signature >"$STATE_FILE"
        show_schedule
        step "Healthcheck OK - Deployment abgeschlossen"
    else
        deploy_signature >"$STATE_FILE"
        show_schedule
        step "Deployment abgeschlossen"
    fi
    if [ "$fresh" = "1" ]; then
        # recordLoom hat keine Registrierung: Ohne Admin kommt niemand hinein.
        info "Ersten Admin anlegen (fragt nach dem Passwort):"
        info "  cd $APP_DIR && sudo -u $APP_USER $PHP_BIN artisan user:admin du@example.com --name=\"Dein Name\""
    fi
}

# Cronjob für den Laravel-Scheduler schreiben (nur wenn er fehlt oder sich
# geändert hat) und prüfen, ob cron läuft. Läuft als Webserver-Benutzer,
# damit Caches und Logs nicht root gehören.
setup_cron() {
    step "Scheduler-Cronjob prüfen"
    if [ ! -d /etc/cron.d ]; then
        warn "/etc/cron.d fehlt (cron nicht installiert) - Scheduler läuft nicht. Installer erneut ausführen."
        return 0
    fi
    local cron_file=/etc/cron.d/recordloom wanted
    wanted="# Generiert von deployLaravel/deploy.sh - Laravel Scheduler von $APP_NAME
SHELL=/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
* * * * * $APP_USER cd $APP_DIR && $(command -v "$PHP_BIN") artisan schedule:run >> /dev/null 2>&1"
    if [ "$(cat "$cron_file" 2>/dev/null)" != "$wanted" ]; then
        printf '%s\n' "$wanted" >"$cron_file"
        info "$cron_file geschrieben"
    fi
    # cron ignoriert Dateien, die nicht root gehören oder für andere
    # beschreibbar sind.
    chown root:root "$cron_file"
    chmod 644 "$cron_file"
    if command -v systemctl >/dev/null && ! systemctl is-active --quiet cron 2>/dev/null; then
        warn "Der Dienst cron läuft nicht - wird gestartet"
        systemctl enable --now cron || warn "cron konnte nicht gestartet werden: systemctl status cron"
    fi
}

# Geplante Aufgaben anzeigen, damit sofort auffällt, wenn eine fehlt (z.B.
# das Mail-Backup ohne BACKUP_MAIL_TO in der .env).
show_schedule() {
    local list
    if list="$(as_app "$PHP_BIN" artisan schedule:list 2>&1)"; then
        step "Geplante Aufgaben (Scheduler läuft jede Minute per cron)"
        printf '%s\n' "$list" | sed -e '/^[[:space:]]*$/d' -e 's/^/    /'
    else
        warn "artisan schedule:list fehlgeschlagen:"
        printf '%s\n' "$list" | sed 's/^/      /'
    fi
}

# Einstellungen aus recordloom.conf lesen. Die Datei wird nicht als Shell-Code
# ausgeführt: Es zählen nur Zeilen der Form NAME="Wert" mit bekannten Namen.
# Umgebungsvariablen haben Vorrang.
load_conf() {
    [ -f "$CONF_FILE" ] || return 0
    local line key value
    while IFS= read -r line || [ -n "$line" ]; do
        [[ "$line" =~ ^([A-Z_]+)=\"?([^\"]*)\"?[[:space:]]*$ ]] || continue
        key="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[2]}"
        case "$key" in
            APP_NAME | APP_REPO | APP_SSH_KEY | APP_BRANCH | APP_DIR | APP_URL | APP_TIMEZONE | \
                PHP_VERSION | NODE_MIN | SEED_DEMO_DATA | KEEP_BACKUPS | MAIL_BACKUP_BEFORE_DEPLOY)
                if [ -z "${!key+set}" ]; then
                    printf -v "$key" '%s' "$value"
                fi
                ;;
        esac
    done <"$CONF_FILE"
}

# Die Werte landen in Befehlen, die als root laufen (chown -R, Cron-Datei,
# sed), deshalb sind nur unverdächtige Zeichen erlaubt.
validate_settings() {
    local bad=""
    [[ "$APP_NAME" =~ ^[A-Za-z0-9\ ._-]+$ ]] || bad="APP_NAME ($APP_NAME)"
    [[ "$APP_REPO" =~ ^(git@[A-Za-z0-9.-]+:[A-Za-z0-9._/-]+|(ssh|https)://[A-Za-z0-9@._:/-]+|(file://)?/[A-Za-z0-9._/-]+)$ ]] ||
        bad="APP_REPO ($APP_REPO)"
    [[ "$APP_BRANCH" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ && "$APP_BRANCH" != *..* ]] || bad="APP_BRANCH ($APP_BRANCH)"
    # Mindestens zwei Ebenen tief und kein Systemverzeichnis: APP_DIR wird
    # rekursiv dem Webserver-Benutzer übereignet.
    [[ "$APP_DIR" =~ ^/[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)+$ && "$APP_DIR" != *..* ]] || bad="APP_DIR ($APP_DIR)"
    case "$APP_DIR" in
        /bin/* | /boot/* | /dev/* | /etc/* | /lib*/* | /proc/* | /root/* | /run/* | /sbin/* | /sys/* | /usr/* | /var/lib/* | /var/log/* | /var/backups/*)
            bad="APP_DIR ($APP_DIR)"
            ;;
    esac
    [[ -z "$APP_URL" || "$APP_URL" =~ ^https?://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._/-]*)?$ ]] || bad="APP_URL ($APP_URL)"
    [[ "$APP_TIMEZONE" =~ ^[A-Za-z0-9_+/-]+$ ]] || bad="APP_TIMEZONE ($APP_TIMEZONE)"
    [[ -z "$APP_SSH_KEY" || "$APP_SSH_KEY" =~ ^/[A-Za-z0-9._/@+-]+$ ]] || bad="APP_SSH_KEY ($APP_SSH_KEY)"
    [[ -z "$PHP_VERSION" || "$PHP_VERSION" =~ ^[0-9]+\.[0-9]+$ ]] || bad="PHP_VERSION ($PHP_VERSION)"
    [[ "$NODE_MIN" =~ ^[0-9]+(\.[0-9]+)*$ ]] || bad="NODE_MIN ($NODE_MIN)"
    [[ "$SEED_DEMO_DATA" =~ ^[01]$ ]] || bad="SEED_DEMO_DATA ($SEED_DEMO_DATA)"
    [[ "$KEEP_BACKUPS" =~ ^[0-9]{1,4}$ ]] || bad="KEEP_BACKUPS ($KEEP_BACKUPS)"
    [[ "$MAIL_BACKUP_BEFORE_DEPLOY" =~ ^[01]$ ]] || bad="MAIL_BACKUP_BEFORE_DEPLOY ($MAIL_BACKUP_BEFORE_DEPLOY)"
    [[ "$APP_USER" =~ ^[a-z_][a-z0-9_-]*$ && "$APP_USER" != root ]] && id "$APP_USER" >/dev/null 2>&1 ||
        bad="APP_USER ($APP_USER)"
    if [ -n "$bad" ]; then
        error "Ungültige Einstellung: $bad - bitte $CONF_FILE prüfen"
        exit 1
    fi
}

# SSH für Git einrichten, wenn das Repository per SSH angesprochen wird.
# www-data kann den Schlüssel von root nicht lesen. Er wird deshalb nur für
# die Dauer des Deployments nach /run kopiert (root gehörend, für www-data
# lesbar) und danach wieder gelöscht: So bleibt bei einer Lücke in der
# Web-App kein Schlüssel liegen, mit dem sich jemand bei GitHub anmelden kann.
setup_git_ssh() {
    # Frühere Versionen haben den Schlüssel dauerhaft hierhin kopiert.
    rm -rf "$APP_HOME/.ssh"
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
        error "Vorhandenen Schlüssel eintragen:  APP_SSH_KEY=\"/home/<user>/.ssh/id_ed25519\" in $CONF_FILE"
        error "oder neuen erzeugen:  ssh-keygen -t ed25519 -N '' -C recordloom-deploy -f /etc/recordloom/deploy_key"
        error "und /etc/recordloom/deploy_key.pub bei GitHub als Deploy-Key des Repositorys hinterlegen."
        exit 1
    fi
    if ! ssh-keygen -y -P "" -f "$SSH_KEY_SOURCE" >/dev/null 2>&1; then
        error "Der SSH-Schlüssel $SSH_KEY_SOURCE ist ungültig oder mit einer Passphrase geschützt."
        error "Das Deployment läuft ohne Rückfragen und braucht einen Schlüssel ohne Passphrase (siehe README)."
        exit 1
    fi
    SSH_TMP="$(mktemp -d /run/recordloom-ssh.XXXXXXXX)"
    chgrp "$APP_GROUP" "$SSH_TMP"
    chmod 750 "$SSH_TMP"
    install -o root -g "$APP_GROUP" -m 640 "$SSH_KEY_SOURCE" "$SSH_TMP/deploy_key"
    # Veröffentlichter Host-Schlüssel von GitHub. Andere Hosts werden beim
    # ersten Kontakt in die Datei von www-data übernommen.
    echo "github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl" >"$SSH_TMP/known_hosts"
    cat >"$SSH_TMP/config" <<EOF
# Generiert von deployLaravel/deploy.sh
Host *
    IdentityFile $SSH_TMP/deploy_key
    IdentitiesOnly yes
    IdentityAgent none
    UserKnownHostsFile $APP_HOME/known_hosts $SSH_TMP/known_hosts
    StrictHostKeyChecking accept-new
    BatchMode yes
EOF
    chmod 644 "$SSH_TMP/known_hosts" "$SSH_TMP/config"
    APP_GIT_SSH="ssh -F $SSH_TMP/config"
}

# Kennung des Zustands, der zuletzt erfolgreich deployt wurde: Commit, dieses
# Skript, Einstellungen, .env sowie PHP- und Node.js-Version.
deploy_signature() {
    local script="${BASH_SOURCE[0]:-}" script_sum conf_sum=""
    # Ohne lesbare Skriptdatei (z.B. "curl | bash") nie überspringen.
    script_sum="$(date +%s%N)"
    if [ -f "$script" ]; then
        script_sum="$(sha256sum <"$script" | cut -d' ' -f1)"
    fi
    if [ -f "$CONF_FILE" ]; then
        conf_sum="$(sha256sum <"$CONF_FILE" | cut -d' ' -f1)"
    fi
    echo "commit=$(as_app git rev-parse HEAD)"
    echo "script=$script_sum"
    echo "conf=$conf_sum"
    echo "settings=$APP_BRANCH $APP_REPO $APP_URL $APP_TIMEZONE"
    echo "env=$(as_app sha256sum .env 2>/dev/null | cut -d' ' -f1)"
    echo "php=$("$PHP_BIN" -r 'echo PHP_VERSION;') node=$(node -v)"
}

# Aktuelle Datenbank per Mail verschicken, genau wie der Cronjob von recordLoom
# (php artisan backup:mail), aber immer, auch ohne Änderung seit dem letzten
# Backup. Bricht das Deployment ab, wenn die Mail nicht verschickt wurde.
mail_backup() {
    if [ ! -s database/database.sqlite ]; then
        info "Noch keine Datenbank - Mail-Backup entfällt"
        return 0
    fi
    step "Datenbank per Mail sichern"
    if [ ! -f vendor/autoload.php ] || [ ! -f .env ]; then
        error "Die bisherige Installation ist unvollständig (vendor/ oder .env fehlt), das Mail-Backup ist nicht möglich."
        error "Ohne Mail-Backup aktualisieren:  recordloom-deploy --no-mail-backup"
        exit 1
    fi
    local problem
    if problem="$(mail_backup_problem)"; then
        error "Mail-Backup nicht möglich: $problem - es wurde nichts geändert."
        error "Einrichten siehe README (Mail-Backup einrichten), danach erneut: recordloom-deploy"
        error "Ohne Mail-Backup aktualisieren:  recordloom-deploy --no-mail-backup"
        error "Dauerhaft abschalten:  MAIL_BACKUP_BEFORE_DEPLOY=\"0\" in $CONF_FILE"
        exit 1
    fi
    # Mit der aktuellen .env statt der gecachten Konfiguration, damit gerade
    # geänderte MAIL_- bzw. BACKUP_-Einstellungen schon gelten. Die Datei
    # existiert nicht: Laravel liest die Konfiguration dann neu ein.
    if ! as_app timeout 300 env APP_CONFIG_CACHE="$APP_HOME/no-config-cache.php" \
        "$PHP_BIN" artisan backup:mail --force --no-interaction; then
        error "Das Mail-Backup ist fehlgeschlagen (Ausgabe siehe oben) - es wurde nichts geändert."
        error "Prüfen: BACKUP_MAIL_TO und MAIL_* in $APP_DIR/.env, Test mit"
        error "  cd $APP_DIR && sudo -u $APP_USER $PHP_BIN artisan backup:mail --force"
        error "Ohne Mail-Backup aktualisieren:  recordloom-deploy --no-mail-backup"
        error "Dauerhaft abschalten:  MAIL_BACKUP_BEFORE_DEPLOY=\"0\" in $CONF_FILE"
        exit 1
    fi
}

# Gibt aus, warum das Mail-Backup laut .env nicht funktionieren kann (Exit 0),
# oder nichts (Exit 1). Mit MAIL_MAILER=log/array meldet backup:mail Erfolg,
# ohne dass eine Mail das System verlässt - das darf nicht als Backup gelten.
mail_backup_problem() {
    local to mailer
    to="$(env_get BACKUP_MAIL_TO)"
    mailer="$(env_get MAIL_MAILER)"
    if [ -z "$to" ] || [ "$to" = null ]; then
        echo "BACKUP_MAIL_TO ist in $APP_DIR/.env nicht gesetzt"
    elif [ -z "$mailer" ] || [ "$mailer" = log ] || [ "$mailer" = array ]; then
        echo "MAIL_MAILER=${mailer:-log} in $APP_DIR/.env verschickt keine Mails (z.B. smtp mit MAIL_HOST usw. eintragen)"
    else
        return 1
    fi
}

# env_get KEY: Wert aus der .env (ohne Anführungszeichen), leer wenn er fehlt
env_get() {
    as_app sed -n "s/^$1=[\"']\{0,1\}\([^\"']*\)[\"']\{0,1\}[[:space:]]*\$/\1/p" .env 2>/dev/null | tail -n1
}

# prune_backups MUSTER: nur die neuesten KEEP_BACKUPS Dateien behalten
prune_backups() {
    find "$BACKUP_DIR" -maxdepth 1 -type f -name "$1" -printf '%T@ %p\n' |
        sort -rn | tail -n +"$((KEEP_BACKUPS + 1))" | cut -d' ' -f2- | xargs -r rm -f --
}

# conf_set KEY VALUE: Wert in recordloom.conf setzen
conf_set() {
    [ -f "$CONF_FILE" ] || return 0
    if grep -q "^$1=" "$CONF_FILE"; then
        sed -i "s|^$1=.*|$1=\"$2\"|" "$CONF_FILE"
    else
        echo "$1=\"$2\"" >>"$CONF_FILE"
    fi
}

# Befehle als Webserver-Benutzer mit leerer, fester Umgebung ausführen (wie
# sudo, das aber in minimalen Containern fehlt) und mit beschreibbarem HOME
# für die Caches von Composer und npm. Ältere Stände von recordLoom enthalten
# noch Puppeteer; dessen Chrome-Download wird nicht gebraucht und schlägt auf
# ARM fehl.
as_app() {
    runuser -u "$APP_USER" -- env -i \
        PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
        LANG=C.UTF-8 \
        HOME="$APP_HOME" \
        COMPOSER_HOME="$APP_HOME/composer" \
        npm_config_cache="$APP_HOME/npm" \
        PUPPETEER_SKIP_DOWNLOAD=true \
        GIT_TERMINAL_PROMPT=0 \
        ${APP_GIT_SSH:+GIT_SSH_COMMAND="$APP_GIT_SSH"} \
        "$@"
}

# env_value KEY VALUE FORCE: setzt KEY in .env (FORCE=1) oder ergänzt ihn nur,
# wenn er fehlt (FORCE=0). Läuft als www-data, damit root nicht in eine Datei
# schreibt, die www-data durch einen Symlink ersetzen könnte.
env_value() {
    local key="$1" value="$2" force="$3"
    case "$value" in
        *[[:space:]]*) value="\"$value\"" ;;
    esac
    if as_app grep -q "^${key}=" .env; then
        if [ "$force" = "1" ]; then
            as_app sed -i "s|^${key}=.*|${key}=${value}|" .env
        fi
    elif as_app grep -q "^# *${key}=" .env; then
        as_app sed -i "s|^# *${key}=.*|${key}=${value}|" .env
    else
        printf '%s\n' "${key}=${value}" | as_app tee -a .env >/dev/null
    fi
}

on_error() {
    local line="$1" caller_line="$2" func="$3" command="$4"
    if [ "$func" = "as_app" ]; then
        error "Abbruch in Zeile $caller_line: ein Befehl als $APP_USER ist fehlgeschlagen (Ausgabe siehe oben)"
    else
        error "Abbruch in Zeile $line (Befehl: $command)"
    fi
}

on_exit() {
    local rc=$?
    trap - ERR
    if [ "${MAINTENANCE:-0}" = "1" ]; then
        # Bei einem Fehler nicht im Wartungsmodus hängen bleiben.
        as_app "$PHP_BIN" artisan up || true
    fi
    if [ -n "${SSH_TMP:-}" ]; then
        rm -rf "$SSH_TMP"
    fi
    if [ "$rc" -ne 0 ]; then
        error "Deployment fehlgeschlagen (Exit-Code $rc) - Protokoll: $LOG_FILE"
    fi
}

step() { echo -e "\n\e[96m==> $*\e[0m"; }
info() { echo -e "\e[90m    $*\e[0m"; }
warn() { echo -e "\e[93m    WARNUNG: $*\e[0m"; }
error() { echo -e "\e[91mFEHLER: $*\e[0m" >&2; }

main "$@"
