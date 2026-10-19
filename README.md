# deployLaravel

Skripte, um [recordLoom](https://github.com/leshaze/recordLoom) (Laravel 13,
SQLite, Vite 8, dompdf) vollautomatisch auf einem Raspberry Pi einzurichten
und später zu aktualisieren.

| Datei          | Zweck                                                                                     |
| -------------- | ----------------------------------------------------------------------------------------- |
| `installer.sh` | Richtet den Pi ein (Pakete, PHP, Node.js, nginx + HTTPS, Absicherung) und deployt danach die App |
| `deploy.sh`    | Installiert bzw. aktualisiert die App; wird als `recordloom-deploy` installiert           |

**Inhalt:**
[Voraussetzungen](#voraussetzungen) ·
[Installation](#installation) ·
[Konfiguration](#konfiguration) ·
[Updates](#updates) ·
[Scheduler](#scheduler-mail-backup-discogs-preise) ·
[Umzug einer alten Installation](#umzug-einer-alten-installation) ·
[Fehlersuche](#fehlersuche) ·
[Dateien und Pfade](#dateien-und-pfade)

## Voraussetzungen

- Raspberry Pi 3, 4 oder 5 (ein Zero 2 W geht, der Build dauert aber sehr lange)
- **Raspberry Pi OS Lite (64-bit)**, Trixie (empfohlen) oder Bookworm.
  recordLoom braucht PHP ≥ 8.4 und Node.js ≥ 24. Unter Bookworm kommt PHP
  aus dem Sury-Repository, Node.js kommt unter beiden Versionen aus
  NodeSource. NodeSource gibt es nur für 64-bit, ein 32-bit-System (`armhf`)
  funktioniert deshalb nicht.
- Im Raspberry Pi Imager unter „Einstellungen bearbeiten“: Hostname
  (z.B. `recordloom`), Benutzer und Passwort, WLAN und **SSH aktivieren**
- Internetzugang während der Installation

## Installation

Pi mit dem Image starten, per SSH anmelden und ausführen:

```bash
curl -fsSL https://raw.githubusercontent.com/leshaze/deployLaravel/main/installer.sh | sudo bash
```

Der Installer läuft ohne Rückfragen durch (je nach Modell 10–30 Minuten) und
endet mit der Adresse der App, z.B. `https://recordloom.local`. Das
Zertifikat ist selbst signiert, der Browser zeigt deshalb einmalig eine
Warnung. Das Protokoll steht in `/var/log/recordloom-install.log`.

Einstellungen lassen sich beim Aufruf mitgeben, z.B.:

```bash
curl -fsSL https://raw.githubusercontent.com/leshaze/deployLaravel/main/installer.sh \
  | sudo APP_HOSTNAME=recordloom SEED_DEMO_DATA=1 bash
```

Der Installer kann jederzeit erneut ausgeführt werden. Er bringt das System
auf den aktuellen Stand und überschreibt weder Daten noch `.env`,
Zertifikat oder die Einstellungen in `/etc/recordloom/recordloom.conf`.

### Was der Installer macht

1. System aktualisieren (`apt full-upgrade`), Zeitzone setzen, optional den Hostnamen
2. Swap auf 1024 MB vergrößern (nur mit `dphys-swapfile`, also bis Bookworm)
3. WLAN-Energiesparmodus über NetworkManager abschalten
4. PHP ≥ 8.4 mit allen Erweiterungen für Laravel, dompdf und die
   Cover-Vorschaubilder (gd) installieren, Upload-Limit 16 MB
5. Composer (Prüfsumme wird online abgeglichen), Node.js ≥ 24 und cron installieren
6. nginx mit HTTPS (selbst signiertes Zertifikat, 10 Jahre gültig) und
   Umleitung von HTTP auf HTTPS einrichten; alte, von Hand angelegte
   nginx-Seiten für die App werden deaktiviert
7. Absicherung:
   - root-Passwort sperren und Root-Login per SSH verbieten (Anmeldung mit dem eigenen Benutzer und `sudo`)
   - Firewall ufw: nur SSH (Port 22), HTTP, HTTPS und mDNS offen
   - fail2ban für SSH
8. `/etc/recordloom/recordloom.conf` schreiben, `recordloom-deploy`
   installieren und die App deployen

### Optionen des Installers

Diese Werte gelten nur für den Installer und werden als Umgebungsvariable übergeben:

| Variable                 | Standard        | Bedeutung                                                     |
| ------------------------ | --------------- | ------------------------------------------------------------- |
| `APP_HOSTNAME`           | *(unverändert)* | Neuer Hostname → `https://<name>.local`                       |
| `PHP_VERSION`            | *(automatisch)* | PHP-Version erzwingen, z.B. `8.5` (mindestens 8.4)            |
| `NODE_MAJOR`             | `24`            | NodeSource-Version, falls Node.js nachinstalliert werden muss |
| `NODE_MIN`               | `24`            | Mindestversion von Node.js                                    |
| `SWAP_SIZE_MB`           | `1024`          | Swap-Größe                                                    |
| `ENABLE_FIREWALL`        | `1`             | ufw einrichten (`0` = nicht anfassen)                         |
| `ENABLE_FAIL2BAN`        | `1`             | fail2ban einrichten                                           |
| `DISABLE_WIFI_POWERSAVE` | `1`             | WLAN-Energiesparen abschalten                                 |
| `REGENERATE_SSH_KEYS`    | `0`             | SSH-Hostschlüssel neu erzeugen (Raspberry Pi OS macht das beim ersten Start bereits selbst) |
| `DEPLOY_SCRIPT_URL`      | `deploy.sh` aus `main` | Woher der Installer `recordloom-deploy` lädt           |

Zusätzlich lassen sich alle Werte aus dem nächsten Abschnitt
(`APP_BRANCH` usw.) mitgeben. Sie landen dann in `recordloom.conf`.

## Konfiguration

`recordloom-deploy` liest seine Einstellungen aus
**`/etc/recordloom/recordloom.conf`**. Die Datei wird vom Installer angelegt
und kann von Hand bearbeitet werden:

```bash
sudo nano /etc/recordloom/recordloom.conf
sudo recordloom-deploy
```

| Variable         | Standard                                    | Bedeutung                                                   |
| ---------------- | ------------------------------------------- | ----------------------------------------------------------- |
| `APP_BRANCH`     | `main`                                      | Branch von recordLoom, der deployt wird                     |
| `APP_REPO`       | `https://github.com/leshaze/recordLoom.git` | Git-Repository der App                                      |
| `APP_DIR`        | `/var/www/recordLoom`                       | Installationsverzeichnis                                    |
| `APP_NAME`       | `recordLoom`                                | Name der App (für die `.env` einer Neuinstallation)         |
| `APP_TIMEZONE`   | `Europe/Berlin`                             | Zeitzone (für die `.env` einer Neuinstallation)             |
| `KEEP_BACKUPS`   | `14`                                        | Anzahl der aufbewahrten Datenbank-Sicherungen               |
| `SEED_DEMO_DATA` | `0`                                         | `1` = Demodaten bei der Erstinstallation einspielen         |
| `PHP_VERSION`    | *(vom Installer)*                           | PHP-Version, mit der `artisan` ausgeführt wird              |
| `NODE_MIN`       | *(vom Installer)*                           | Unterhalb dieser Node.js-Version warnt das Deploy-Skript    |

`PHP_VERSION` und `NODE_MIN` bestimmt der Installer bei jedem Lauf neu, alle
anderen Werte bleiben bei einem erneuten Lauf erhalten.

### Anderen Branch deployen

Dauerhaft: `APP_BRANCH` in `/etc/recordloom/recordloom.conf` ändern und
`sudo recordloom-deploy` ausführen.

Einmalig, ohne die Datei zu ändern (Umgebungsvariablen haben Vorrang vor
der Datei):

```bash
sudo APP_BRANCH=dev recordloom-deploy
```

Existiert der eingestellte Branch nicht mehr (z.B. weil er gemergt und
gelöscht wurde), deployt das Skript mit einer Warnung `main` und setzt
`APP_BRANCH` in der Datei auf `main` zurück.

### Konfiguration der App (`.env`)

Die Einstellungen von recordLoom selbst stehen in `/var/www/recordLoom/.env`.
Bei einer Neuinstallation erzeugt `recordloom-deploy` sie aus
`.env.example` und setzt dabei u.a. `APP_ENV=production`, `APP_DEBUG=false`,
`APP_URL=https://<hostname>.local`, `APP_LOCALE=de`, `LOG_LEVEL=warning`
(tägliche Logdateien, 14 Tage) und `SESSION_SECURE_COOKIE=true`. Bei
späteren Läufen ergänzt es nur fehlende Werte, eigene Änderungen bleiben
erhalten.

Nach jeder Änderung an der `.env` den Konfigurations-Cache neu aufbauen,
sonst bleibt die alte Konfiguration aktiv:

```bash
cd /var/www/recordLoom && sudo -u www-data php artisan optimize
```

## Updates

```bash
sudo recordloom-deploy
```

Das Skript

1. schaltet den Wartungsmodus ein,
2. setzt den Code auf den Stand von `origin/<APP_BRANCH>`. Lokale Änderungen
   am Code werden vorher als Patch nach `/var/backups/recordloom/`
   gesichert und dann verworfen; `.env`, Datenbank und Cover bleiben erhalten,
3. führt `composer install --no-dev`, `npm ci` und `npm run build` aus,
4. sichert die SQLite-Datenbank nach `/var/backups/recordloom/`,
5. führt `php artisan migrate --force` aus,
6. baut die Laravel-Caches neu (`php artisan optimize`), schreibt den
   Cronjob für den Scheduler und lädt PHP-FPM neu,
7. beendet den Wartungsmodus (auch wenn ein Schritt fehlschlägt) und prüft
   `https://localhost/up`.

Alle Befehle laufen als `www-data`, dem Besitzer der App-Dateien.

`recordloom-deploy` ist eine Kopie von `deploy.sh`. Neue Versionen des
Skripts kommen auf den Pi, wenn der Installer erneut läuft, oder direkt mit:

```bash
sudo curl -fsSLo /usr/local/sbin/recordloom-deploy https://raw.githubusercontent.com/leshaze/deployLaravel/main/deploy.sh
```

## Scheduler (Mail-Backup, Discogs-Preise)

`recordloom-deploy` schreibt `/etc/cron.d/recordloom`. Der Cronjob startet
jede Minute den Laravel-Scheduler als `www-data`:

```
* * * * * www-data cd /var/www/recordLoom && /usr/bin/php8.x artisan schedule:run >> /dev/null 2>&1
```

recordLoom prüft damit alle 15 Minuten, ob eine Aufgabe fällig ist, und holt
verpasste Läufe nach (z.B. wenn der Pi aus war). Gesteuert wird das über die
`.env`:

| Variable                       | Wert vom Deploy | Bedeutung                                                     |
| ------------------------------ | --------------- | ------------------------------------------------------------- |
| `BACKUP_MAIL_TO`               | *(leer)*        | Empfänger des Mail-Backups – ohne Wert kein Backup            |
| `BACKUP_INTERVAL_DAYS`         | `1`             | Abstand der Mail-Backups in Tagen (nur wenn sich etwas geändert hat) |
| `DISCOGS_TOKEN`                | *(leer)*        | Persönlicher Token von discogs.com → Settings → Developers    |
| `DISCOGS_NIGHTLY_PRICES`       | `false`         | `true` = Discogs-Preise automatisch abgleichen                |
| `DISCOGS_PRICE_INTERVAL_HOURS` | `24`            | Abstand des Discogs-Preisabgleichs in Stunden                 |

Für das Mail-Backup braucht es außerdem eine funktionierende
Mail-Konfiguration: `MAIL_MAILER`, `MAIL_HOST`, `MAIL_PORT`,
`MAIL_USERNAME`, `MAIL_PASSWORD`, `MAIL_FROM_ADDRESS`.

### Scheduler prüfen

```bash
cat /etc/cron.d/recordloom                          # Cronjob vorhanden?
systemctl status cron --no-pager                    # cron läuft?
journalctl -u cron --since "5 min ago" | grep schedule:run   # jede Minute ein Aufruf?

cd /var/www/recordLoom
sudo -u www-data php artisan schedule:list          # geplante Aufgaben
sudo -u www-data php artisan schedule:run           # einmal von Hand anstoßen
sudo cat storage/app/private/schedule/last-runs.json   # letzte Läufe
```

`schedule:list` zeigt nur die Aufgaben, die aktiviert sind:
`backup:mail --if-due` nur mit gesetztem `BACKUP_MAIL_TO`,
`discogs:update-prices --if-due` nur mit `DISCOGS_TOKEN` und
`DISCOGS_NIGHTLY_PRICES=true`. Fehlt eine Aufgabe trotz richtiger `.env`,
wurde nach der Änderung `php artisan optimize` vergessen.

Die Aufgaben lassen sich auch direkt starten:

```bash
sudo -u www-data php artisan backup:mail --force     # Backup sofort mailen
sudo -u www-data php artisan discogs:update-prices   # Preise sofort abgleichen
```

## Umzug einer alten Installation

Eine Installation, die mit älteren Versionen dieser Skripte bzw. nach der
alten Anleitung eingerichtet wurde, wird mit dem **Installer** umgestellt.
`recordloom-deploy` gibt es dort noch nicht, und PHP und Node.js sind zu alt.

1. Datenbank und `.env` vom Pi auf einen anderen Rechner kopieren
   (`/var/www/recordLoom/database/database.sqlite`, `/var/www/recordLoom/.env`).
2. Prüfen, dass alle bisherigen Migrationen gelaufen sind:
   `cd /var/www/recordLoom && sudo -u www-data php artisan migrate:status`
3. Installer wie oben ausführen.

Der Installer deaktiviert die alte nginx-Seite. Die App ist danach nur noch
über HTTPS erreichbar. Das Deploy-Skript übernimmt die vorhandene `.env`,
ergänzt fehlende Werte und migriert die Datenbank. Werte, die die Migration
nicht exakt umwandeln kann (z.B. ein Datum wie „12.03.1974“), hängt
recordLoom an die Notiz des Datensatzes an.

## Fehlersuche

| Problem                                   | Lösung                                                         |
| ----------------------------------------- | -------------------------------------------------------------- |
| Installer bricht ab                       | Meldung im Terminal bzw. in `/var/log/recordloom-install.log`; der Installer kann einfach erneut gestartet werden |
| Deploy bricht ab                          | Der Wartungsmodus wird trotzdem beendet. Fehler beheben und `sudo recordloom-deploy` erneut ausführen, bis es durchläuft – vorher können Code und Datenbank auf unterschiedlichem Stand sein |
| Fehlerseite / HTTP 500                    | `sudo tail -n 50 /var/www/recordLoom/storage/logs/laravel-$(date +%F).log` |
| `.env` geändert, aber keine Wirkung       | `cd /var/www/recordLoom && sudo -u www-data php artisan optimize` |
| Warnung „Node.js … ist älter als 24“      | Installer erneut ausführen                                     |
| Warnung „Lokale Änderungen … verworfen“   | Die Änderungen liegen als `local-changes-*.patch` in `/var/backups/recordloom/` |

### Datenbank-Sicherung zurückspielen

Das Deploy-Skript sichert die Datenbank vor jeder Migration nach
`/var/backups/recordloom/database-<Datum>-<Zeit>.sqlite`:

```bash
cd /var/www/recordLoom
sudo -u www-data php artisan down
sudo cp /var/backups/recordloom/database-<Datum>-<Zeit>.sqlite database/database.sqlite
sudo chown www-data:www-data database/database.sqlite
sudo -u www-data php artisan up
```

Stammt die Sicherung von vor einem Update, danach `sudo recordloom-deploy`
ausführen, damit die Migrationen des aktuellen Codes erneut auf die
Datenbank angewendet werden.

### Skripte aus einem anderen Branch von deployLaravel testen

Der Installer lädt `deploy.sh` standardmäßig aus `main`. Für einen anderen
Branch beide URLs anpassen (`<branch>` ersetzen):

```bash
curl -fsSL https://raw.githubusercontent.com/leshaze/deployLaravel/<branch>/installer.sh \
  | sudo DEPLOY_SCRIPT_URL=https://raw.githubusercontent.com/leshaze/deployLaravel/<branch>/deploy.sh bash
```

Aus einem Klon (`git clone -b <branch> https://github.com/leshaze/deployLaravel.git`
und `sudo ./deployLaravel/installer.sh`) wird automatisch das `deploy.sh`
daneben verwendet.

## Dateien und Pfade

| Was                         | Pfad                                                  |
| --------------------------- | ----------------------------------------------------- |
| Einstellungen des Deploys   | `/etc/recordloom/recordloom.conf`                     |
| Deploy-Skript               | `/usr/local/sbin/recordloom-deploy`                   |
| App                         | `/var/www/recordLoom`                                 |
| Konfiguration der App       | `/var/www/recordLoom/.env`                            |
| Datenbank                   | `/var/www/recordLoom/database/database.sqlite`        |
| Cover-Bilder                | `/var/www/recordLoom/storage/app/private/covers`      |
| Laravel-Logs                | `/var/www/recordLoom/storage/logs/`                   |
| Datenbank-Sicherungen, Patches | `/var/backups/recordloom/`                         |
| Scheduler-Cronjob           | `/etc/cron.d/recordloom`                              |
| Installer-Protokoll         | `/var/log/recordloom-install.log`                     |
| nginx                       | `/etc/nginx/sites-available/recordloom`               |
| Zertifikat                  | `/etc/ssl/recordloom/`                                |
| PHP-Einstellungen           | `/etc/php/<Version>/fpm/conf.d/99-recordloom.ini`     |
| fail2ban                    | `/etc/fail2ban/jail.d/recordloom.local`               |
| SSH (kein Root-Login)       | `/etc/ssh/sshd_config.d/10-recordloom.conf`           |
| Caches von Composer und npm | `/var/lib/recordloom/`                                |
