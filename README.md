# Beschreibung
Ein paar nützliche Befehle und Skripte für das Aufsetzen vom raspberry pi und deployment einer Laravel-Anwendung von Git

# Setup raspberryPi
Ausführen von raspi-config um das Dateisystem zu erweitern und den GPU Ram zu reduzieren, da der Server Headless betrieben werden soll.

```
sudo raspi-config -> Advanced Options -> Expand Filesystem

sudo raspi-config -> Performance Options -> GPU Memory -> Wert auf 16 ändern

```

System rebooten und wieder anmelden.
Danach die *installer.sh* Datei ausführen.
Dadurch werden die SSH-Schlüssel neu generiert, sowie der root SSH-Login deaktiviert. Außerdem werden die benötigten Pakete installiert und das System aktualisiert.

# Hardening raspberryPi



# Deployment
Siehe deploy.sh
