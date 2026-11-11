# deployLaravel

Skripte, um [recordLoom](https://github.com/leshaze/recordLoom) (Laravel 13,
SQLite, Vite 8, dompdf) vollautomatisch in einem **Proxmox-Container mit
Debian 13** einzurichten und später zu aktualisieren. Ein Raspberry Pi mit
Raspberry Pi OS funktioniert weiterhin (siehe
[Raspberry Pi](#raspberry-pi)).

| Datei          | Zweck                                                                                     |
| -------------- | ----------------------------------------------------------------------------------------- |
| `installer.sh` | Richtet das System ein (Pakete, PHP, Node.js, nginx + HTTPS) und deployt danach die App   |
| `deploy.sh`    | Installiert bzw. aktualisiert die App; wird als `recordloom-deploy` installiert           |

**Inhalt:**
[Voraussetzungen](#voraussetzungen) ·
[Installation](#installation) ·
[Konfiguration](#konfiguration) ·
[Updates](#updates) ·
[Scheduler](#scheduler-mail-backup-discogs-preise) ·
[Umzug vom Raspberry Pi](#umzug-vom-raspberry-pi-in-den-container) ·
[Fehlersuche](#fehlersuche) ·
[Dateien und Pfade](#dateien-und-pfade)

## Voraussetzungen

Ein LXC-Container in Proxmox (*Create CT*):

| Einstellung      | Empfehlung                                                              |
| ---------------- | ----------------------------------------------------------------------- |
| Template         | `debian-13-standard` (amd64)                                            |
| Typ              | unprivilegiert, Option **Nesting** aktiv (Standard bei neuen Containern; Debian 13 braucht es für systemd) |
| Hostname         | z.B. `recordloom` → die App ist unter `https://recordloom.local` erreichbar |
| CPU / RAM / Swap | 2 Kerne, 2048 MB RAM, 512 MB Swap (der Frontend-Build braucht Speicher) |
| Disk             | 8 GB (App mit `vendor/` und `node_modules/` etwa 1 GB, dazu Daten und Sicherungen) |
| Netzwerk         | feste IP-Adresse oder DHCP-Reservierung, damit die Adresse der App gleich bleibt |

Internetzugang ist während der Installation nötig. recordLoom braucht
PHP ≥ 8.4 (in Debian 13 enthalten) und Node.js ≥ 24 (kommt von NodeSource).

## Installation

Container starten und als root eine Konsole öffnen (Proxmox-Oberfläche
*Console* oder `pct enter <ID>` auf dem Proxmox-Host).

**1. Deploy-Key für das private Repository anlegen.** recordLoom ist privat,
der Container braucht deshalb einen SSH-Schlüssel mit Lesezugriff:

```bash
apt update && apt install -y curl openssh-client
mkdir -p /etc/recordloom
ssh-keygen -t ed25519 -N "" -C "recordloom-deploy@$(hostname)" -f /etc/recordloom/deploy_key
cat /etc/recordloom/deploy_key.pub
```

Die ausgegebene Zeile bei GitHub eintragen: recordLoom → *Settings → Deploy
keys → Add deploy key*, **ohne** „Allow write access“. Ein Deploy-Key gilt
nur für dieses eine Repository und kann nur lesen. Der Schlüssel darf keine
Passphrase haben, weil das Deploy-Skript ohne Rückfragen läuft.

Gibt es auf dem System schon einen passenden Schlüssel (z.B.
`/root/.ssh/id_ed25519`, der bei GitHub hinterlegt ist), kann dieser Schritt
entfallen, siehe [SSH-Schlüssel](#ssh-schlüssel-für-das-private-repository).

**2. Installer starten:**

```bash
curl -fsSL https://raw.githubusercontent.com/leshaze/deployLaravel/main/installer.sh | bash
```

Findet der Installer keinen Schlüssel, erzeugt er selbst
`/etc/recordloom/deploy_key`, zeigt den öffentlichen Schlüssel an und hält
vor dem Deployment an. Nach dem Eintragen bei GitHub die Installation mit
`recordloom-deploy` abschließen.

Der Installer läuft ohne Rückfragen durch (10–20 Minuten) und endet mit der
Adresse der App, z.B. `https://recordloom.local` (zusätzlich ist sie über
die IP-Adresse erreichbar). Das Zertifikat ist selbst signiert, der Browser
zeigt deshalb einmalig eine Warnung. Das Protokoll steht in
`/var/log/recordloom-install.log`.

`<hostname>.local` funktioniert per mDNS: Der Container meldet sich über
avahi selbst im Netz, ein DNS-Server ist nicht nötig. Windows 10/11, macOS,
iOS und die meisten Linux-Systeme lösen solche Namen auf, Android nur
teilweise. Ist die Proxmox-Firewall für den Container aktiv, zusätzlich
UDP 5353 erlauben.

Soll die App stattdessen unter einem Namen aus dem lokalen DNS (z.B. vom
Router oder Pi-hole) laufen, diesen als Adresse mitgeben. Er landet dann in
der `.env` (für Links in Mails) und im Zertifikat:

```bash
curl -fsSL https://raw.githubusercontent.com/leshaze/deployLaravel/main/installer.sh \
  | APP_URL=https://recordloom.fritz.box bash
```

Der Installer kann jederzeit erneut ausgeführt werden. Er bringt das System
auf den aktuellen Stand und überschreibt weder Daten noch `.env`,
Zertifikat oder die Einstellungen in `/etc/recordloom/recordloom.conf`.

Alle Befehle in dieser Anleitung laufen als root. Der Installer richtet
auch `sudo` ein; als root kann es vor den Befehlen entfallen.

### Was der Installer macht

1. System aktualisieren (`apt full-upgrade`), Zeitzone setzen
2. PHP ≥ 8.4 mit allen Erweiterungen für Laravel, dompdf und die
   Cover-Vorschaubilder (gd) installieren, Upload-Limit 16 MB
3. Composer (Prüfsumme wird online abgeglichen), Node.js ≥ 24, cron und sudo installieren
4. nginx mit HTTPS (selbst signiertes Zertifikat, 10 Jahre gültig) und
   Umleitung von HTTP auf HTTPS einrichten; alte, von Hand angelegte
   nginx-Seiten für die App werden deaktiviert. IPv6 wird nur verwendet,
   wenn der Container es hat.
5. `/etc/recordloom/recordloom.conf` schreiben, `recordloom-deploy`
   installieren und die App deployen (ohne SSH-Schlüssel vorher einen
   Deploy-Key erzeugen, siehe oben)

Im Container erkennt der Installer, dass er nicht auf echter Hardware läuft,
und lässt alles weg, was dort Sache von Proxmox ist:

| Thema               | Im Container                                                              | Auf einem Raspberry Pi                    |
| ------------------- | ------------------------------------------------------------------------- | ----------------------------------------- |
| Firewall            | keine – in Proxmox unter *Container → Firewall* nur TCP 22, 80, 443 und UDP 5353 erlauben | ufw: SSH, HTTP, HTTPS, mDNS |
| fail2ban            | nein                                                                      | ja, für SSH                               |
| mDNS (`name.local`) | ja (avahi, für Container angepasst)                                       | ja (avahi)                                |
| Hostname            | in Proxmox setzen (*Container → DNS*), bestimmt `<hostname>.local`        | über `APP_HOSTNAME`                       |
| Swap                | in Proxmox setzen                                                         | 1024 MB über `dphys-swapfile` (bis Bookworm) |
| root sperren        | nur, wenn es einen anderen Benutzer mit sudo-Rechten gibt                  | ja (dort gibt es immer einen)             |

### Optionen des Installers

Diese Werte gelten nur für den Installer und werden als Umgebungsvariable übergeben:

| Variable                 | Standard                | Bedeutung                                                     |
| ------------------------ | ----------------------- | ------------------------------------------------------------- |
| `APP_URL`                | `https://<hostname>.local` | Adresse der App; wird in `recordloom.conf` gespeichert (ohne laufendes mDNS die IP) |
| `PHP_VERSION`            | *(automatisch)*         | PHP-Version erzwingen, z.B. `8.5` (mindestens 8.4)            |
| `NODE_MAJOR`             | `24`                    | NodeSource-Version, falls Node.js nachinstalliert werden muss |
| `NODE_MIN`               | `24`                    | Mindestversion von Node.js                                    |
| `ENABLE_FIREWALL`        | Container `0`, sonst `1` | ufw einrichten                                               |
| `ENABLE_FAIL2BAN`        | Container `0`, sonst `1` | fail2ban einrichten                                          |
| `ENABLE_MDNS`            | `1`                     | avahi für `https://<hostname>.local`                          |
| `LOCK_ROOT`              | `auto`                  | root-Passwort sperren und Root-Login per SSH verbieten; `auto` = nur, wenn ein anderer Benutzer sudo-Rechte hat |
| `APP_HOSTNAME`           | *(unverändert)*         | Neuer Hostname (nur Raspberry Pi; im Container in Proxmox setzen) |
| `SWAP_SIZE_MB`           | `1024`                  | Swap-Größe (nur Raspberry Pi mit `dphys-swapfile`)            |
| `DISABLE_WIFI_POWERSAVE` | `1`                     | WLAN-Energiesparen abschalten (nur mit WLAN)                  |
| `REGENERATE_SSH_KEYS`    | `0`                     | SSH-Hostschlüssel neu erzeugen                                |
| `DEPLOY_SCRIPT_URL`      | `deploy.sh` aus `main`  | Woher der Installer `recordloom-deploy` lädt                  |

Zusätzlich lassen sich alle Werte aus dem nächsten Abschnitt
(`APP_BRANCH` usw.) mitgeben. Sie landen dann in `recordloom.conf`.

### Raspberry Pi

Auf einem Raspberry Pi 3, 4 oder 5 mit **Raspberry Pi OS Lite (64-bit)**,
Trixie oder Bookworm, funktionieren die Skripte genauso. Im Raspberry Pi
Imager Hostname, Benutzer, WLAN und SSH einrichten, per SSH anmelden und
ausführen:

```bash
curl -fsSL https://raw.githubusercontent.com/leshaze/deployLaravel/main/installer.sh | sudo bash
```

Den Deploy-Key wie oben anlegen (mit `sudo` vor den Befehlen) oder vom
Installer erzeugen lassen. Unter Bookworm kommt PHP 8.4 aus dem Sury-Repository. Ein 32-bit-System
(`armhf`) funktioniert nicht, weil es Node.js 24 dafür nicht gibt.

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
| `APP_REPO`       | `git@github.com:leshaze/recordLoom.git`     | Git-Repository der App (SSH)                                |
| `APP_SSH_KEY`    | *(automatisch)*                             | Privater SSH-Schlüssel für das Repository, siehe unten      |
| `APP_DIR`        | `/var/www/recordLoom`                       | Installationsverzeichnis                                    |
| `APP_URL`        | *(vom Installer)*                           | Adresse der App (für die `.env` einer Neuinstallation)      |
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

### SSH-Schlüssel für das private Repository

Git läuft als `www-data`, der Schlüssel von root ist für diesen Benutzer
nicht lesbar. `recordloom-deploy` kopiert ihn deshalb bei jedem Lauf nach
`/var/lib/recordloom/.ssh/` und richtet dort eine eigene SSH-Konfiguration
ein (inklusive des Host-Schlüssels von GitHub). Der Schlüssel wird in dieser
Reihenfolge gesucht:

1. `APP_SSH_KEY` aus `recordloom.conf`, falls gesetzt
2. `/etc/recordloom/deploy_key`
3. `/root/.ssh/id_ed25519`
4. `/root/.ssh/id_rsa`

Liegt der Schlüssel woanders (z.B. im Home-Verzeichnis eines anderen
Benutzers), den Pfad in `recordloom.conf` eintragen:

```bash
APP_SSH_KEY="/home/pi/.ssh/id_ed25519"
```

Zugriff testen:

```bash
ssh -i /etc/recordloom/deploy_key -T git@github.com
```

GitHub antwortet mit „Hi leshaze/recordLoom! You've successfully
authenticated …“. Ältere Installationen mit der früheren HTTPS-Adresse
stellt `recordloom-deploy` automatisch auf SSH um.

### Konfiguration der App (`.env`)

Die Einstellungen von recordLoom selbst stehen in `/var/www/recordLoom/.env`.
Bei einer Neuinstallation erzeugt `recordloom-deploy` sie aus
`.env.example` und setzt dabei u.a. `APP_ENV=production`, `APP_DEBUG=false`,
`APP_URL` (aus `recordloom.conf`), `APP_LOCALE=de`, `LOG_LEVEL=warning`
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
Skripts kommen auf das System, wenn der Installer erneut läuft, oder direkt mit:

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
verpasste Läufe nach (z.B. wenn der Container aus war). Gesteuert wird das über die
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

## Umzug vom Raspberry Pi in den Container

Der Container wird zuerst wie oben neu installiert. Danach kommen Datenbank,
Cover und `.env` vom Pi herüber. Der Pi muss dafür nicht auf dem neuesten
Stand sein: Die Migrationen laufen anschließend im Container.

**1. Auf dem Pi** die App anhalten (damit sich nichts mehr ändert) und die
Daten einpacken:

```bash
cd /var/www/recordLoom
sudo -u www-data php artisan down
sudo sqlite3 database/database.sqlite ".backup '/tmp/recordloom.sqlite'"
sudo tar -czf /tmp/recordloom-files.tgz .env storage/app/private
sudo chown "$USER" /tmp/recordloom.sqlite /tmp/recordloom-files.tgz
sudo chmod 600 /tmp/recordloom.sqlite /tmp/recordloom-files.tgz
```

**2. Im Container** (als root) die Dateien vom Pi holen und einspielen
(`pi@192.168.1.20` durch Benutzer und Adresse des Pi ersetzen):

```bash
scp pi@192.168.1.20:/tmp/recordloom.sqlite pi@192.168.1.20:/tmp/recordloom-files.tgz /root/
mkdir -p /root/vom-pi && tar -xzf /root/recordloom-files.tgz -C /root/vom-pi

cd /var/www/recordLoom
sudo -u www-data php artisan down
cp /root/recordloom.sqlite database/database.sqlite
cp -a /root/vom-pi/storage/app/private/. storage/app/private/
cp /root/vom-pi/.env .env
chown -R www-data:www-data database storage .env
nano .env        # APP_URL prüfen (wie in /etc/recordloom/recordloom.conf)
recordloom-deploy
```

Die alte `.env` bringt `APP_KEY` sowie die Mail-, Backup- und
Discogs-Einstellungen mit. `recordloom-deploy` ergänzt fehlende Werte,
migriert die Datenbank und nimmt die App wieder online. Werte, die eine
Migration nicht exakt umwandeln kann (z.B. ein Datum wie „12.03.1974“),
hängt recordLoom an die Notiz des Datensatzes an.

**3. Auf dem Pi** danach den Scheduler abschalten, sonst verschickt er
weiter Backups. Haben Pi und Container denselben Hostnamen, den Pi am besten
ganz ausschalten: Sonst melden sich beide per mDNS, und einer wird zu
`<hostname>-2.local`.

```bash
sudo rm /etc/cron.d/recordloom
```

Eine Installation nach der alten Anleitung dieses Repositories (vor
`recordloom-deploy`) wird genauso umgezogen. Vorher auf dem Pi prüfen,
dass alle bisherigen Migrationen gelaufen sind:
`sudo -u www-data php artisan migrate:status`.

## Fehlersuche

| Problem                                   | Lösung                                                         |
| ----------------------------------------- | -------------------------------------------------------------- |
| „Kein Zugriff auf git@github.com:…“       | Deploy-Key bei GitHub hinterlegt? Mit `ssh -i <schlüssel> -T git@github.com` testen; siehe [SSH-Schlüssel](#ssh-schlüssel-für-das-private-repository) |
| Installer bricht ab                       | Meldung im Terminal bzw. in `/var/log/recordloom-install.log`; der Installer kann einfach erneut gestartet werden |
| Deploy bricht ab                          | Der Wartungsmodus wird trotzdem beendet. Fehler beheben und `sudo recordloom-deploy` erneut ausführen, bis es durchläuft – vorher können Code und Datenbank auf unterschiedlichem Stand sein |
| Fehlerseite / HTTP 500                    | `sudo tail -n 50 /var/www/recordLoom/storage/logs/laravel-$(date +%F).log` |
| `.env` geändert, aber keine Wirkung       | `cd /var/www/recordLoom && sudo -u www-data php artisan optimize` |
| Warnung „Node.js … ist älter als 24“      | Installer erneut ausführen                                     |
| Im Container starten Dienste nicht (z.B. nginx, php-fpm, cron) | In Proxmox unter *Container → Options → Features* **Nesting** aktivieren und den Container neu starten |
| App im Netz nicht erreichbar              | Proxmox-Firewall des Containers bzw. Datacenters: TCP 80 und 443 erlauben |
| Links in Mails zeigen auf die falsche Adresse | `APP_URL` in der `.env` korrigieren, danach `php artisan optimize` |
| `<hostname>.local` nicht erreichbar       | `systemctl status avahi-daemon` im Container; Proxmox-Firewall: UDP 5353 erlauben; auf dem Rechner `ping <hostname>.local` testen (Android kann `.local` oft nicht) |
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
| Deploy-Key (privat / öffentlich) | `/etc/recordloom/deploy_key`, `/etc/recordloom/deploy_key.pub` |
| SSH-Kopie für `www-data`    | `/var/lib/recordloom/.ssh/`                           |
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
| fail2ban (nur Raspberry Pi) | `/etc/fail2ban/jail.d/recordloom.local`               |
| SSH (kein Root-Login, nur wenn root gesperrt) | `/etc/ssh/sshd_config.d/10-recordloom.conf` |
| Caches von Composer und npm | `/var/lib/recordloom/`                                |
