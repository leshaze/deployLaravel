#!/usr/bin/env bash

# Clear Screen
clear

#Disable apt.systemd.daily
echo -e "\e[96mDisable apt.systemd.daily\e[90m"
sudo systemctl stop apt-daily.timer
sudo systemctl disable apt-daily.timer
sudo systemctl disable apt-daily.service
sudo systemctl daemon-reload

echo -e "\e[96mDisable Wifi Autosleep\e[90m"
sudo touch /etc/network/interfaces.d/wifi
sudo sh -c ' echo "allow-hotplug wlan0
iface wlan0 inet manual
wpa-conf /etc/wpa_supplicant/wpa_supplicant.conf 
wireless-power off" >> /etc/network/interfaces.d/wifi'

# Renew ssh certificates
echo -e "\e[96mRemoving the old SSH certificates\e[90m"
sudo rm /etc/ssh/ssh_host_*
echo -e "\e[96mGenerating new certificates\e[90m"
sudo dpkg-reconfigure openssh-server
echo -e "\e[96mRestarting SSH\e[90m"
sudo service ssh restart

# Disable root login
echo -e "\e[96mDisable root login\e[90m"
sudo passwd -d root
                                                        
# Updating the fresh installation
echo -e "\e[96mUpdating the system ...\e[90m"
sudo apt update && sudo apt upgrade -y || exit

# Installing helper tools
echo -e "\e[96mInstalling helper tools ...\e[90m"
sudo apt -y install curl wget git build-essential unzip|| exit
                                                                
# Installing PHP 8.1 and nginx
echo -e "\e[96mInstalling PHP, sqlite and nginx ...\e[90m"
sudo curl -sSL https://packages.sury.org/php/README.txt | sudo bash -x
sudo apt -y install nginx php8.3 php8.3-fpm php8.3-cli php8.3-curl php8.3-sqlite3 php8.3-xml sqlite3 libsqlite3-dev php-mbstring php-xml php-bcmath chromium || exit

# Install npm and nodejs
echo -e "\e[96mInstalling NPM\e[90m"
sudo apt -y install npm nodejs || exit

# Install composer
echo -e "\e[96mInstalling Composer\e[90m"
php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
php -r "if (hash_file('sha384', 'composer-setup.php') === 'dac665fdc30fdd8ec78b38b9800061b4150413ff2e3b6f88543c636f7cd84f6db9189d43a81e5503cda447da73c7e5b6') { echo 'Installer verified'; } else { echo 'Installer corrupt'; unlink('composer-setup.php'); } echo PHP_EOL;"
php composer-setup.php
php -r "unlink('composer-setup.php');"
sudo mv composer.phar /usr/local/bin/composer