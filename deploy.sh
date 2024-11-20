#!/usr/bin/env bash

clear
echo "Start deployment..."
echo "Check if directory exist..."
if [ ! -d "/var/www/recordLoom" ] 
then
    echo "Directory does not exist"
    echo "Clone repository"
    git clone https://github.com/leshaze/recordLoom.git
    sudo mv recordLoom /var/www/recordLoom
    
    echo "Starting maintenance mode"
    cd /var/www/recordLoom
    touch database/database.sqlite
    sudo chmod 775 /var/www/recordLoom/database/database.sqlite
    touch .env
    echo "APP_NAME=recordLoom" >> .env
    echo "APP_ENV=production" >> .env
    echo "APP_KEY=" >> .env
    echo "APP_DEBUG=false" >> .env
    echo "LOG_CHANNEL=stack" >> .env
    echo "LOG_DEPRECATIONS_CHANNEL=null" >> .env
    echo "LOG_LEVEL=debug" >> .env
    echo "DB_CONNECTION=sqlite" >> .env
    echo "BROADCAST_DRIVER=log" >> .env
    echo "CACHE_DRIVER=file" >> .env
    echo "FILESYSTEM_DRIVER=local" >> .env
       
    echo "Composer install"
    composer install --optimize-autoloader --no-dev
    npm run build

    echo "Storage linking"
    php artisan storage:link

    echo "Generate Key"
    php artisan key:generate
    
    #echo "Artisan migrate and seed"
    #php artisan migrate:fresh --seed

    echo "Puppeteer-Config for PDF with chromium"
    touch .puppeteerrc.cjs
    echo "const {join} = require('path');" >> .puppeteerrc.cjs
    echo "/**" >> .puppeteerrc.cjs
    echo "* @type {import("puppeteer").Configuration}" >> .puppeteerrc.cjs
    echo "*/" >> .puppeteerrc.cjs
    echo "module.exports = {" >> .puppeteerrc.cjs
    echo "// Changes the cache location for Puppeteer." >> .puppeteerrc.cjs
    echo "cacheDirectory: join(__dirname, '.cache', 'puppeteer')," >> .puppeteerrc.cjs
    echo "executablePath: '/usr/bin/chromium'" >> .puppeteerrc.cjs
    echo "};" >> .puppeteerrc.cjs

else 
    echo "Directory does exist"
    echo "Starting maintenance mode"
    
    cd /var/www/recordLoom
    sudo php artisan down
    wait

    echo "Get new changes"
    git fetch   
    git reset --hard HEAD
    sudo git pull --no-rebase origin main
    
    echo "Composer install"
    sudo -u www-data composer install --optimize-autoloader --no-dev
    sudo -u www-data npm run build
    
    #echo "Artisan migrate"
    #php artisan migrate
    echo "Chown www-data"
    sudo chown -R www-data:www-data /var/www/recordLoom
    sudo chmod -R 775 /var/www/recordLoom/storage
    sudo chmod -R 775 /var/www/recordLoom/bootstrap/cache

    echo "Ending maintenance mode"
    sudo php artisan up

fi

echo "Chown www-data"
sudo chown -R www-data:www-data /var/www/recordLoom
sudo chmod -R 775 /var/www/recordLoom/storage
sudo chmod -R 775 /var/www/recordLoom/bootstrap/cache

echo "Deployment complete. Have a nice day"