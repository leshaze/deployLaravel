#!/usr/bin/env bash

clear
echo "Start deployment..."
echo "Check if directory exist..."
if [ ! -d "/var/www/recordsArchive" ] 
then
    echo "Directory does not exist"
    echo "Clone repository"
    git clone https://github.com/leshaze/recordsArchive.git
    sudo mv recordsArchive /var/www/recordsArchive
    
    echo "Starting maintenance mode"
    cd /var/www/recordsArchive
    touch database/database.sqlite
    sudo chmod 775 /var/www/recordsArchive/database/database.sqlite
    touch .env
    echo "APP_NAME=recordsArchive" >> .env
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
    npm run prod

    echo "Storage linking"
    php artisan storage:link
    
    #echo "Artisan migrate and seed"
    #php artisan migrate:fresh --seed

else 
    echo "Directory does exist"
    echo "Starting maintenance mode"
    cd /var/www/recordsArchive
    php artisan down
    wait

    echo "Get new changes"
    git fetch   
    git reset --hard HEAD
    sudo git pull --no-rebase origin main
    
    echo "Composer install"
    sudo -u www-data composer install --optimize-autoloader --no-dev
    sudo -u www-data npm run prod
    
    #echo "Artisan migrate"
    #php artisan migrate

fi

echo "Chown www-data"
sudo chown -R www-data:www-data /var/www/recordsArchive
sudo chmod -R 775 /var/www/recordsArchive/storage
sudo chmod -R 775 /var/www/recordsArchive/bootstrap/cache

echo "Ending maintenance mode"
php artisan up

echo "Deployment complete. Have a nice day"
