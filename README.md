# deployLaravel

Skripte, um [recordLoom](https://github.com/leshaze/recordLoom) (Laravel 13,
SQLite, Vite 8, dompdf) – standardmäßig den Branch
`claude/upgrade-security-0h8wx0` – vollautomatisch auf einem frischen Raspberry Pi
einzurichten und später zu aktualisieren.

| Datei          | Zweck                                                                                   |
| -------------- | --------------------------------------------------------------------------------------- |
| `installer.sh` | Einmalige Einrichtung des Pi: Pakete, PHP, Composer, Node.js, nginx + HTTPS, Absicherung, danach Deployment |
| `deploy.sh`    | Installiert/aktualisiert die App (wird als `recordloom-deploy` installiert)             |

## Voraussetzungen

- Raspberry Pi 3/4/5 (Zero 2 W geht, der Build dauert aber lange)
- **Raspberry Pi OS Lite (64-bit)**, Trixie (empfohlen) oder Bookworm.
  Unter Bookworm kommt PHP 8.4 aus dem Sury-Repository, da die
  Distribution nur PHP 8.2 enthält. Node.js 22 kommt unter beiden aus
  NodeSource (Bookworm hat Node.js 18, Trixie Node.js 20);
  dafür ist die 64-bit-Variante zwingend.
- Im Raspberry Pi Imager unter „Einstellungen bearbeiten“: Hostname
  (z.B. `recordloom`), Benutzer + Passwort, WLAN und **SSH aktivieren**
- Internetzugang während der Installation

## Installation

Pi mit dem Image starten, per SSH anmelden und einen Befehl ausführen:

```bash
curl -fsSL https://raw.githubusercontent.com/leshaze/deployLaravel/main/installer.sh | sudo bash
```

Das Skript läuft ohne Rückfragen durch (je nach Modell 10–30 Minuten) und
endet mit der Adresse der App, z.B. `https://recordloom.local`. Das
Zertifikat ist selbst signiert, der Browser zeigt deshalb einmalig eine
Warnung. Das komplette Protokoll steht in `/var/log/recordloom-install.log`.

Alternativ aus einem Klon des Repositories:

```bash
git clone https://github.com/leshaze/deployLaravel.git
sudo ./deployLaravel/installer.sh
```

### Installation aus einem anderen Branch von deployLaravel

Um die Skripte aus einem anderen Branch als `main` zu verwenden (z.B. zum
Testen von Änderungen), muss der Branch sowohl für `installer.sh` als auch
für das `deploy.sh` angegeben werden, das der Installer nachlädt (ohne
`DEPLOY_SCRIPT_URL` würde er das `deploy.sh` aus `main` holen).
`<branch>` durch den Namen des Branches ersetzen:

```bash
curl -fsSL https://raw.githubusercontent.com/leshaze/deployLaravel/<branch>/installer.sh | sudo DEPLOY_SCRIPT_URL=https://raw.githubusercontent.com/leshaze/deployLaravel/<branch>/deploy.sh bash
```

Aus einem Klon ist das nicht nötig, dort wird das `deploy.sh` neben dem
Installer verwendet:

```bash
git clone -b <branch> https://github.com/leshaze/deployLaravel.git
sudo ./deployLaravel/installer.sh
```

Welcher Branch von **recordLoom** deployt wird, legt dagegen `APP_BRANCH`
fest (siehe Einstellungen).

### Was der Installer macht

1. System aktualisieren (`apt full-upgrade`), Zeitzone setzen, optional Hostname setzen
2. Swap auf 1024 MB vergrößern (nur wenn `dphys-swapfile` vorhanden ist, also bis Bookworm)
3. WLAN-Energiesparmodus über NetworkManager abschalten
4. PHP 8.4 installieren (aus der Distribution, sonst aus dem
   Sury-Repository) inkl. aller Erweiterungen für Laravel, dompdf und die
   Cover-Vorschaubilder (gd), Upload-Limit 16 MB
5. Composer (Prüfsumme wird online abgeglichen) und Node.js ≥ 22.12 mit npm
   installieren (aus der Distribution, sonst NodeSource 22.x)
6. nginx mit HTTPS (selbst signiertes Zertifikat, 10 Jahre gültig) und
   Umleitung von HTTP auf HTTPS einrichten
7. Absicherung: Root-Konto sperren, Root-Login per SSH verbieten, Firewall
   (ufw: SSH, HTTP, HTTPS, mDNS), fail2ban für SSH
8. `recordloom-deploy` installieren und die App deployen

### Einstellungen

Alle Werte lassen sich per Umgebungsvariable überschreiben:

```bash
curl -fsSL https://raw.githubusercontent.com/leshaze/deployLaravel/main/installer.sh \
  | sudo APP_HOSTNAME=recordloom SEED_DEMO_DATA=1 bash
```

| Variable                 | Standard                                     | Bedeutung                                     |
| ------------------------ | -------------------------------------------- | --------------------------------------------- |
| `APP_HOSTNAME`           | *(unverändert)*                              | Neuer Hostname → `https://<name>.local`       |
| `APP_REPO`               | `https://github.com/leshaze/recordLoom.git`  | Git-Repository der App                        |
| `APP_BRANCH`             | `claude/upgrade-security-0h8wx0`             | Branch, der deployt wird                      |
| `APP_DIR`                | `/var/www/recordLoom`                        | Installationsverzeichnis                      |
| `APP_TIMEZONE`           | `Europe/Berlin`                              | Zeitzone von System und App                   |
| `PHP_VERSION`            | *(automatisch)*                              | z.B. `8.5` erzwingen (mindestens 8.4)         |
| `NODE_MAJOR`             | `22`                                         | NodeSource-Version, falls nötig               |
| `NODE_MIN`               | `22.12`                                      | Mindestversion von Node.js                    |
| `SWAP_SIZE_MB`           | `1024`                                       | Swap-Größe                                    |
| `ENABLE_FIREWALL`        | `1`                                          | ufw einrichten                                |
| `ENABLE_FAIL2BAN`        | `1`                                          | fail2ban einrichten                           |
| `DISABLE_WIFI_POWERSAVE` | `1`                                          | WLAN-Energiesparen abschalten                 |
| `REGENERATE_SSH_KEYS`    | `0`                                          | SSH-Hostschlüssel neu erzeugen (Raspberry Pi OS macht das beim ersten Start bereits selbst) |
| `SEED_DEMO_DATA`         | `0`                                          | Demodaten bei der Erstinstallation einspielen |

Die für Updates relevanten Werte speichert der Installer in
`/etc/recordloom/recordloom.conf`.

## Updates

```bash
sudo recordloom-deploy
```

Das Skript

1. schaltet den Wartungsmodus ein,
2. setzt den Code auf den Stand von `origin/<branch>`; lokale Änderungen im Code werden vorher als Patch nach `/var/backups/recordloom/` gesichert und dann verworfen (`.env`, Datenbank und Uploads bleiben erhalten),
3. führt `composer install --no-dev`, `npm ci` und `npm run build` aus,
4. sichert die SQLite-Datenbank nach `/var/backups/recordloom/` (die letzten 14 Sicherungen bleiben erhalten),
5. führt `php artisan migrate --force` aus,
6. baut die Laravel-Caches neu (`php artisan optimize`), lädt PHP-FPM neu,
7. beendet den Wartungsmodus – auch wenn ein Schritt fehlschlägt – und prüft `https://localhost/up`.

Alle Befehle laufen als `www-data`, der Besitzer der App-Dateien.

## Nützliches

| Was                         | Wo / Befehl                                        |
| --------------------------- | -------------------------------------------------- |
| App-Konfiguration           | `/var/www/recordLoom/.env`                         |
| Datenbank                   | `/var/www/recordLoom/database/database.sqlite`     |
| Cover-Bilder                | `/var/www/recordLoom/storage/app/private/covers`   |
| Laravel-Log                 | `/var/www/recordLoom/storage/logs/`                |
| nginx-Konfiguration         | `/etc/nginx/sites-available/recordloom`            |
| Datenbank-Sicherungen       | `/var/backups/recordloom/`                         |
| Sicherung wiederherstellen  | `sudo -u www-data cp /var/backups/recordloom/<datei> /var/www/recordLoom/database/database.sqlite` |

Nach Änderungen an der `.env`:

```bash
cd /var/www/recordLoom && sudo -u www-data php artisan optimize
```
