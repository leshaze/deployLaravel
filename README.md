# Beschreibung
Ein paar nützliche Befehle und Skripte für das Aufsetzen vom raspberry pi und deployment einer Laravel-Anwendung von Git

# Setup raspberryPi
1. Ausführen von raspi-config um das Dateisystem zu erweitern und den GPU Ram zu reduzieren, da der Server Headless betrieben werden soll.

```
sudo raspi-config -> Advanced Options -> Expand Filesystem

sudo raspi-config -> Performance Options -> GPU Memory -> Wert auf 16 ändern

```

2. System rebooten und wieder anmelden.

3. Erweitern der Swap-Datei
```
sudo su -c 'echo "CONF_SWAPSIZE=1024" > /etc/dphys-swapfile'
sudo dphys-swapfile setup
sudo dphys-swapfile swapon
```

4. Danach die *installer.sh* Datei ausführen.
Dadurch werden die SSH-Schlüssel neu generiert, sowie der root SSH-Login deaktiviert. Außerdem werden benötigten Pakete installiert und das System aktualisiert.


# Hardening raspberryPi
Um das System weiter abzusichern empfehlen sich noch folgende Änderungen, diese Änderungen sind aber nur nötig, wenn eine Verbindung ins Internet besteht. 

## Anlegen von einem neuen Benutzer

## Aktivieren und Konfigurieren der Firewall

## Änderungen an SSH

## Installation und Konfigration von fail2ban

# Einrichten von nginx mit https und selbst signiertem Zertifikat
Erstellen von einem eigenen Zertifikat
```
sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout /etc/ssl/private/nginx-selfsigned.key -out /etc/ssl/certs/nginx-selfsigned.crt

sudo openssl dhparam -out /etc/nginx/dhparam.pem 4096

```

Anlegen von zwei snipped Dateien für die spätere nginx conf-Datei
```
sudo nano /etc/nginx/snippets/self-signed.conf
```
wird mit folgendem Inhalt gefüllt. Hiermit wird auf die selbsterstellten Zertifkate verwiesen.
```
ssl_certificate /etc/ssl/certs/nginx-selfsigned.crt;
ssl_certificate_key /etc/ssl/private/nginx-selfsigned.key;
```

Jetzt noch die Datei für die ssl-parameter
```
sudo nano /etc/nginx/snippets/ssl-params.conf
```
mit folgendem Inhalt
```
ssl_protocols TLSv1.3;
ssl_prefer_server_ciphers on;
ssl_dhparam /etc/nginx/dhparam.pem; 
ssl_ciphers EECDH+AESGCM:EDH+AESGCM;
ssl_ecdh_curve secp384r1;
ssl_session_timeout  10m;
ssl_session_cache shared:SSL:10m;
ssl_session_tickets off;
ssl_stapling on;
ssl_stapling_verify on;
resolver 8.8.8.8 8.8.4.4 valid=300s;
resolver_timeout 5s;
# Disable strict transport security for now. You can uncomment the following
# line if you understand the implications.
#add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload";
add_header X-Frame-Options DENY;
add_header X-Content-Type-Options nosniff;
add_header X-XSS-Protection "1; mode=block";
```

Erstellen einer neuen nginx Konfiguration
```
sudo nano /etc/nginx/sites-available/recordsarchive
```
Folgenden Inhalt einfügen
```
server {
    listen 443 ssl;
    server_name 192.168.178.82;
    include snippets/self-signed.conf;
    include snippets/ssl-params.conf;
    root /var/www/recordsArchive/public;

    add_header X-Frame-Options "SAMEORIGIN";
    add_header X-XSS-Protection "1; mode=block";
    add_header X-Content-Type-Options "nosniff";

    index index.php index.html index.htm;

    charset utf-8;

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }

    error_page 404 /index.php;

    location ~ \.php$ {
        fastcgi_pass unix:/var/run/php/php8.1-fpm.sock;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME $realpath_root$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.(?!well-known).* {
        deny all;
    }
}
server {
 listen 80;
 server_name 192.168.178.82;
 return 301 https://$server_name$request_uri;
}

```
Durch den letzten Block wird http traffic auf https umgeleitet.

Hinzufügen von einem symbolischen Link

```
sudo ln -s /etc/nginx/sites-available/recordsarchive /etc/nginx/sites-enabled/
```
Mit  ```sudo nginx -t``` überprüfen ob die Konfigdatei Fehler enthält.

Sind keine Fehler vorhanden muss nginx neugestartet werden.
```
sudo systemctl reload nginx


# Deployment
Siehe deploy.sh
