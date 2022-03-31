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
sudo apt-get update && sudo apt-get upgrade -y || exit

# Installing helper tools
echo -e "\e[96mInstalling helper tools ...\e[90m"
sudo apt-get -y install curl wget git build-essential unzip|| exit
                                                                
# Installing PHP 8.1 and nginx
echo -e "\e[96mInstalling PHP, sqlite and nginx ...\e[90m"
sudo curl -sSL https://packages.sury.org/php/README.txt | sudo bash -x
sudo apt-get -y install nginx php8.1 php8.1-fpm php8.1-cli php8.1-curl php8.1-sqlite3 php8.1-xml sqlite3 libsqlite3-dev php-mbstring php-xml php-bcmath || exit

# Install npm and nodejs
echo -e "\e[96mInstalling NPM\e[90m"
sudo apt-get -y install npm nodejs || exit

# Install composer
echo -e "\e[96mInstalling Composer\e[90m"
php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
php -r "if (hash_file('sha384', 'composer-setup.php') === '906a84df04cea2aa72f4>
php composer-setup.php
php -r "unlink('composer-setup.php');"
sudo mv composer.phar /usr/local/bin/composer
