# deployLaravel

Skripte, um [recordLoom](https://github.com/leshaze/recordLoom) (Laravel 11,
SQLite, Vite, dompdf) vollautomatisch auf einem frischen Raspberry Pi
einzurichten und später zu aktualisieren.

| Datei          | Zweck                                                                                   |
| -------------- | --------------------------------------------------------------------------------------- |
| `installer.sh` | Einmalige Einrichtung des Pi: Pakete, PHP, Composer, Node.js, nginx + HTTPS, Absicherung, danach Deployment |
| `deploy.sh`    | Installiert/aktualisiert die App (wird als `recordloom-deploy` installiert)             |

## Voraussetzungen

- Raspberry Pi 3/4/5 (Zero 2 W geht, der Build dauert aber lange)
- **Raspberry Pi OS Lite (64-bit)**, Bookworm oder Trixie
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

### Was der Installer macht

1. System aktualisieren (`apt full-upgrade`), Zeitzone setzen, optional Hostname setzen
2. Swap auf 1024 MB vergrößern (nur wenn `dphys-swapfile` vorhanden ist, also bis Bookworm)
3. WLAN-Energiesparmodus über NetworkManager abschalten
4. PHP 8.2–8.4 aus der Distribution installieren (sonst PHP 8.3 aus dem
   Sury-Repository) inkl. aller Erweiterungen für Laravel und dompdf,
   Upload-Limit 16 MB
5. Composer (Prüfsumme wird online abgeglichen), Node.js und npm installieren
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
| `APP_BRANCH`             | `main`                                       | Branch, der deployt wird                      |
| `APP_DIR`                | `/var/www/recordLoom`                        | Installationsverzeichnis                      |
| `APP_TIMEZONE`           | `Europe/Berlin`                              | Zeitzone von System und App                   |
| `PHP_VERSION`            | *(automatisch)*                              | z.B. `8.3` erzwingen                          |
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
2. setzt den Code auf den Stand von `origin/<branch>` (lokale Änderungen im Code werden verworfen; `.env`, Datenbank und Uploads bleiben erhalten),
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
| Hochgeladene Bilder         | `/var/www/recordLoom/storage/app/public/images`    |
| Laravel-Log                 | `/var/www/recordLoom/storage/logs/`                |
| nginx-Konfiguration         | `/etc/nginx/sites-available/recordloom`            |
| Datenbank-Sicherungen       | `/var/backups/recordloom/`                         |
| Sicherung wiederherstellen  | `sudo -u www-data cp /var/backups/recordloom/<datei> /var/www/recordLoom/database/database.sqlite` |

Nach Änderungen an der `.env`:

```bash
cd /var/www/recordLoom && sudo -u www-data php artisan optimize
```
