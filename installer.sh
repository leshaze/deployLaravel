#!/usr/bin/env bash
#
# Vollautomatische Einrichtung eines frischen Raspberry Pi (Raspberry Pi OS
# Lite, Bookworm oder Trixie) für recordLoom.
#
# Aufruf (auf dem Pi, als Benutzer mit sudo-Rechten):
#   curl -fsSL https://raw.githubusercontent.com/leshaze/deployLaravel/main/installer.sh | sudo bash
#
# Alle Einstellungen können per Umgebungsvariable überschrieben werden, z.B.:
#   curl -fsSL .../installer.sh | sudo APP_HOSTNAME=recordloom bash
#
# Das Skript ist idempotent: ein erneuter Aufruf bringt System und App auf
# den aktuellen Stand, ohne Daten zu verlieren.

# Alles steckt in main(), damit bash bei "curl | bash" das komplette Skript
# einliest, bevor ein Befehl stdin lesen kann.
main() {
    set -Eeuo pipefail
    exec </dev/null

    # ------------------------------------------------------------------ Config
    APP_NAME="${APP_NAME:-recordLoom}"
    APP_REPO="${APP_REPO:-https://github.com/leshaze/recordLoom.git}"
    APP_BRANCH="${APP_BRANCH:-main}"
    APP_DIR="${APP_DIR:-/var/www/recordLoom}"
    # Neuer Hostname für den Pi (leer = unverändert lassen). Die App ist
    # anschließend unter https://<hostname>.local erreichbar.
    APP_HOSTNAME="${APP_HOSTNAME:-}"
    APP_TIMEZONE="${APP_TIMEZONE:-Europe/Berlin}"
    # PHP-Version (leer = Version der Distribution, sofern 8.4 oder 8.5,
    # sonst 8.4 aus dem Sury-Repository). recordLoom (Laravel 13 / Symfony 8)
    # benötigt PHP >= 8.4.1.
    PHP_VERSION="${PHP_VERSION:-}"
    # Node.js-Hauptversion aus NodeSource, falls die Distribution kein
    # Node.js >= NODE_MIN mitbringt. recordLoom benötigt Node.js 24
    # (@zxing/library für den Barcode-Scan).
    NODE_MAJOR="${NODE_MAJOR:-24}"
    NODE_MIN="${NODE_MIN:-24}"
    SWAP_SIZE_MB="${SWAP_SIZE_MB:-1024}"
    ENABLE_FIREWALL="${ENABLE_FIREWALL:-1}"
    ENABLE_FAIL2BAN="${ENABLE_FAIL2BAN:-1}"
    DISABLE_WIFI_POWERSAVE="${DISABLE_WIFI_POWERSAVE:-1}"
    # Raspberry Pi OS erzeugt beim ersten Start bereits eigene SSH-Schlüssel.
    REGENERATE_SSH_KEYS="${REGENERATE_SSH_KEYS:-0}"
    SEED_DEMO_DATA="${SEED_DEMO_DATA:-0}"
    DEPLOY_SCRIPT_URL="${DEPLOY_SCRIPT_URL:-https://raw.githubusercontent.com/leshaze/deployLaravel/main/deploy.sh}"

    CONF_DIR=/etc/recordloom
    LOG_FILE=/var/log/recordloom-install.log
    CERT_DIR=/etc/ssl/recordloom

    if [ "$(id -u)" -ne 0 ]; then
        echo "Bitte mit sudo ausführen." >&2
        exit 1
    fi

    exec > >(tee -a "$LOG_FILE") 2>&1
    trap 'error "Abbruch in Zeile $LINENO (Befehl: $BASH_COMMAND). Details: $LOG_FILE"' ERR

    export DEBIAN_FRONTEND=noninteractive
    export NEEDRESTART_MODE=a

    step "Starte Installation von $APP_NAME ($(date))"
    # shellcheck disable=SC1091
    . /etc/os-release
    info "System: $PRETTY_NAME ($(dpkg --print-architecture))"

    # ------------------------------------------------------------ System update
    step "System aktualisieren"
    apt_get update
    apt_get -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold full-upgrade
    apt_get install ca-certificates curl git unzip openssl sqlite3 lsb-release avahi-daemon iw cron
    systemctl enable --now cron

    # ------------------------------------------------------- Hostname/Zeitzone
    if [ -n "$APP_HOSTNAME" ] && [ "$(hostname)" != "$APP_HOSTNAME" ]; then
        step "Hostname auf $APP_HOSTNAME setzen"
        hostnamectl set-hostname "$APP_HOSTNAME"
        if grep -q '^127\.0\.1\.1' /etc/hosts; then
            sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t$APP_HOSTNAME/" /etc/hosts
        else
            printf '127.0.1.1\t%s\n' "$APP_HOSTNAME" >>/etc/hosts
        fi
        systemctl restart avahi-daemon || true
    fi
    step "Zeitzone auf $APP_TIMEZONE setzen"
    timedatectl set-timezone "$APP_TIMEZONE" || warn "Zeitzone konnte nicht gesetzt werden"

    # -------------------------------------------------------------------- Swap
    # Der Vite-Build braucht auf Modellen mit wenig RAM zusätzlichen Swap.
    if [ -f /etc/dphys-swapfile ] && command -v dphys-swapfile >/dev/null; then
        step "Swap auf ${SWAP_SIZE_MB} MB setzen"
        if grep -q '^#\?CONF_SWAPSIZE=' /etc/dphys-swapfile; then
            sed -i "s/^#\?CONF_SWAPSIZE=.*/CONF_SWAPSIZE=$SWAP_SIZE_MB/" /etc/dphys-swapfile
        else
            echo "CONF_SWAPSIZE=$SWAP_SIZE_MB" >>/etc/dphys-swapfile
        fi
        dphys-swapfile swapoff || true
        dphys-swapfile setup
        dphys-swapfile swapon
    else
        info "dphys-swapfile nicht vorhanden (ab Trixie verwaltet rpi-swap/zram den Swap) - übersprungen"
    fi

    # ------------------------------------------------------ WLAN Energiesparen
    if [ "$DISABLE_WIFI_POWERSAVE" = "1" ]; then
        step "WLAN-Energiesparmodus deaktivieren"
        if [ -d /etc/NetworkManager/conf.d ]; then
            printf '[connection]\nwifi.powersave = 2\n' >/etc/NetworkManager/conf.d/99-recordloom-wifi-powersave.conf
        fi
        if [ -e /sys/class/net/wlan0 ]; then
            iw dev wlan0 set power_save off || true
        fi
    fi

    # --------------------------------------------------------------------- PHP
    step "PHP installieren"
    if [ -z "$PHP_VERSION" ]; then
        local distro_php
        distro_php="$(apt-cache depends php-fpm 2>/dev/null | grep -oP 'php\K[0-9]+\.[0-9]+(?=-fpm)' | head -n1 || true)"
        case "$distro_php" in
            8.4 | 8.5) PHP_VERSION="$distro_php" ;;
            *) PHP_VERSION=8.4 ;;
        esac
    fi
    if ! apt-cache show "php${PHP_VERSION}-fpm" >/dev/null 2>&1; then
        info "php${PHP_VERSION} nicht in der Distribution - Sury-Repository wird eingerichtet"
        curl -fsSLo /tmp/debsuryorg-archive-keyring.deb https://packages.sury.org/debsuryorg-archive-keyring.deb
        dpkg -i /tmp/debsuryorg-archive-keyring.deb
        rm -f /tmp/debsuryorg-archive-keyring.deb
        echo "deb [signed-by=/usr/share/keyrings/deb.sury.org-php.gpg] https://packages.sury.org/php/ $(lsb_release -sc) main" \
            >/etc/apt/sources.list.d/php-sury.list
        apt_get update
    fi
    info "Verwende PHP $PHP_VERSION"
    local php_pkgs=(fpm cli common sqlite3 mbstring xml curl zip gd bcmath intl)
    php_pkgs=("${php_pkgs[@]/#/php${PHP_VERSION}-}")
    # Ab PHP 8.5 ist OPcache fest eingebaut und kein eigenes Paket mehr.
    if apt-cache show "php${PHP_VERSION}-opcache" >/dev/null 2>&1; then
        php_pkgs+=("php${PHP_VERSION}-opcache")
    fi
    apt_get install "${php_pkgs[@]}"
    update-alternatives --set php "/usr/bin/php${PHP_VERSION}" >/dev/null 2>&1 || true

    cat >"/etc/php/${PHP_VERSION}/fpm/conf.d/99-recordloom.ini" <<'EOF'
; recordLoom: Bild-Uploads und PDF-Erzeugung (dompdf)
upload_max_filesize = 16M
post_max_size = 20M
memory_limit = 256M
max_execution_time = 120
expose_php = Off
opcache.enable = 1
opcache.memory_consumption = 64
opcache.max_accelerated_files = 10000
opcache.validate_timestamps = 1
EOF
    systemctl enable --now "php${PHP_VERSION}-fpm"
    systemctl restart "php${PHP_VERSION}-fpm"

    # ---------------------------------------------------------------- Composer
    step "Composer installieren"
    if command -v composer >/dev/null; then
        composer self-update --2 --no-interaction || warn "composer self-update fehlgeschlagen"
    else
        local expected actual
        expected="$(curl -fsSL https://composer.github.io/installer.sig)"
        curl -fsSLo /tmp/composer-setup.php https://getcomposer.org/installer
        actual="$(php -r "echo hash_file('sha384', '/tmp/composer-setup.php');")"
        if [ "$expected" != "$actual" ]; then
            rm -f /tmp/composer-setup.php
            error "Composer-Installer: Prüfsumme stimmt nicht"
            exit 1
        fi
        php /tmp/composer-setup.php --quiet --install-dir=/usr/local/bin --filename=composer
        rm -f /tmp/composer-setup.php
    fi
    composer --version

    # ---------------------------------------------------------- Node.js / npm
    step "Node.js und npm installieren"
    local node_candidate
    node_candidate="$(apt-cache policy nodejs 2>/dev/null | awk '/Candidate:/ {print $2}')"
    if [ -f /etc/apt/sources.list.d/nodesource.list ] ||
        ! dpkg --compare-versions "${node_candidate:-0}" ge "$NODE_MIN"; then
        info "Node.js der Distribution (${node_candidate:-keins}) ist zu alt - NodeSource $NODE_MAJOR.x wird eingerichtet"
        case "$(dpkg --print-architecture)" in
            arm64 | amd64) ;;
            *)
                error "NodeSource unterstützt $(dpkg --print-architecture) nicht - bitte Raspberry Pi OS (64-bit) verwenden"
                exit 1
                ;;
        esac
        apt_get install gnupg
        install -d -m 755 /etc/apt/keyrings
        curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key |
            gpg --dearmor --yes -o /etc/apt/keyrings/nodesource.gpg
        echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
            >/etc/apt/sources.list.d/nodesource.list
        apt_get update
        # Das nodejs-Paket von NodeSource bringt npm mit und kollidiert mit
        # dem npm-Paket der Distribution.
        apt_get purge npm || true
        apt_get install nodejs
        apt_get autoremove --purge
    else
        apt_get install nodejs npm
    fi
    if ! dpkg --compare-versions "$(node -p 'process.versions.node')" ge "$NODE_MIN"; then
        error "Node.js $(node -v) ist zu alt (benötigt wird >= $NODE_MIN)"
        exit 1
    fi
    info "Node.js $(node -v), npm $(npm -v)"

    # ------------------------------------------------------------------ nginx
    step "nginx mit HTTPS (selbst signiertes Zertifikat) einrichten"
    apt_get install nginx
    local host
    host="$(hostname)"
    install -d -m 755 "$CERT_DIR"
    if [ ! -s "$CERT_DIR/recordloom.crt" ]; then
        local san="DNS:${host},DNS:${host}.local,DNS:localhost,IP:127.0.0.1"
        local ip
        for ip in $(hostname -I 2>/dev/null); do
            case "$ip" in *:*) ;; *) san="$san,IP:$ip" ;; esac
        done
        openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
            -keyout "$CERT_DIR/recordloom.key" -out "$CERT_DIR/recordloom.crt" \
            -subj "/CN=${host}.local" -addext "subjectAltName=$san"
        chmod 600 "$CERT_DIR/recordloom.key"
    else
        info "Zertifikat existiert bereits - übersprungen"
    fi

    cat >/etc/nginx/sites-available/recordloom <<EOF
# Generiert von deployLaravel/installer.sh
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;
    server_name _;
    root ${APP_DIR}/public;

    ssl_certificate ${CERT_DIR}/recordloom.crt;
    ssl_certificate_key ${CERT_DIR}/recordloom.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:10m;
    ssl_session_tickets off;

    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    index index.php;
    charset utf-8;
    client_max_body_size 20M;

    gzip on;
    gzip_types text/css application/javascript application/json image/svg+xml;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location /build/ {
        expires 1y;
        access_log off;
        add_header Cache-Control "public, immutable";
    }

    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }

    error_page 404 /index.php;

    location ~ ^/index\.php(/|\$) {
        fastcgi_pass unix:/run/php/php${PHP_VERSION}-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_hide_header X-Powered-By;
        fastcgi_read_timeout 120s;
    }

    # Andere PHP-Dateien weder ausführen noch als Quelltext ausliefern.
    location ~ \.php\$ {
        return 404;
    }

    location ~ /\.(?!well-known).* {
        deny all;
    }
}
EOF
    rm -f /etc/nginx/sites-enabled/default
    ln -sf /etc/nginx/sites-available/recordloom /etc/nginx/sites-enabled/recordloom
    nginx -t
    systemctl enable nginx
    systemctl reload-or-restart nginx

    # -------------------------------------------------------------- Hardening
    step "Root-Konto sperren und Root-Login per SSH deaktivieren"
    passwd -l root
    if [ -d /etc/ssh/sshd_config.d ]; then
        printf 'PermitRootLogin no\n' >/etc/ssh/sshd_config.d/10-recordloom.conf
    fi
    if [ "$REGENERATE_SSH_KEYS" = "1" ]; then
        info "SSH-Hostschlüssel werden neu erzeugt"
        rm -f /etc/ssh/ssh_host_*
        ssh-keygen -A
    fi
    if command -v sshd >/dev/null && sshd -t; then
        systemctl reload ssh || systemctl reload sshd || true
    fi

    if [ "$ENABLE_FIREWALL" = "1" ]; then
        step "Firewall (ufw) einrichten"
        apt_get install ufw
        ufw allow OpenSSH >/dev/null || ufw allow 22/tcp >/dev/null
        ufw allow 80/tcp >/dev/null
        ufw allow 443/tcp >/dev/null
        ufw allow 5353/udp >/dev/null # mDNS (<hostname>.local)
        ufw --force enable
    fi

    if [ "$ENABLE_FAIL2BAN" = "1" ]; then
        step "fail2ban einrichten"
        apt_get install fail2ban python3-systemd
        # Seit Bookworm gibt es kein /var/log/auth.log mehr -> journald nutzen.
        cat >/etc/fail2ban/jail.d/recordloom.local <<'EOF'
[sshd]
enabled = true
backend = systemd
maxretry = 5
bantime = 1h
EOF
        systemctl enable fail2ban
        systemctl restart fail2ban
    fi

    # ------------------------------------------------------------------ Deploy
    step "Deploy-Skript installieren"
    install -d -m 755 "$CONF_DIR"
    cat >"$CONF_DIR/recordloom.conf" <<EOF
# Generiert von deployLaravel/installer.sh - wird von recordloom-deploy gelesen
APP_NAME="$APP_NAME"
APP_REPO="$APP_REPO"
APP_BRANCH="$APP_BRANCH"
APP_DIR="$APP_DIR"
APP_TIMEZONE="$APP_TIMEZONE"
PHP_VERSION="$PHP_VERSION"
NODE_MIN="$NODE_MIN"
SEED_DEMO_DATA="$SEED_DEMO_DATA"
SCHEDULE_CRON="${SCHEDULE_CRON:-23 4 * * 0}"
EOF
    local script_dir=""
    if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
        script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    fi
    if [ -n "$script_dir" ] && [ -f "$script_dir/deploy.sh" ]; then
        install -m 755 "$script_dir/deploy.sh" /usr/local/sbin/recordloom-deploy
    else
        curl -fsSLo /usr/local/sbin/recordloom-deploy "$DEPLOY_SCRIPT_URL"
        chmod 755 /usr/local/sbin/recordloom-deploy
    fi

    step "recordLoom deployen"
    /usr/local/sbin/recordloom-deploy

    trap - ERR
    step "Fertig"
    echo -e "\e[92m$APP_NAME ist betriebsbereit:\e[0m"
    echo "  https://$(hostname).local"
    for ip in $(hostname -I 2>/dev/null); do
        case "$ip" in *:*) ;; *) echo "  https://$ip" ;; esac
    done
    echo "Hinweis: Das Zertifikat ist selbst signiert - der Browser zeigt einmalig eine Warnung."
    echo "Updates einspielen: sudo recordloom-deploy"
    echo "Log: $LOG_FILE"
}

apt_get() {
    apt-get -y -q -o DPkg::Lock::Timeout=600 "$@"
}
step() { echo -e "\n\e[96m==> $*\e[0m"; }
info() { echo -e "\e[90m    $*\e[0m"; }
warn() { echo -e "\e[93m    WARNUNG: $*\e[0m"; }
error() { echo -e "\e[91mFEHLER: $*\e[0m" >&2; }

main "$@"
