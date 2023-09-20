#!/bin/bash

# Проверка наличия sudo и его установка, если отсутствует
if ! command -v sudo &> /dev/null; then
    echo "Установка sudo..."
    apt update
    apt install -y sudo
fi

# Функция для проверки установки пакета
check_package_installed() {
    if dpkg -l | grep -q $1; then
        echo "$1 уже установлен."
        return 0
    else
        return 1
    fi
}

# Установка Apache, если не установлен
if ! check_package_installed "apache2"; then
    sudo apt update
    sudo apt install -y apache2
fi

# Изменение порта в файле ports.conf
sudo sed -i 's/Listen 80/Listen 8080/' /etc/apache2/ports.conf
sudo sed -i '/Listen 8080/a Listen 8081\nListen 8082\nListen 8083' /etc/apache2/ports.conf


# Установка MariaDB, если не установлен
if ! check_package_installed "mariadb-server"; then
    sudo apt install -y mariadb-server
fi

# Установка PHP и необходимых расширений, если не установлены
if ! check_package_installed "php"; then
    sudo apt install -y php libapache2-mod-php php-mysql
fi

# Настройка Apache для обработки файлов PHP
sudo sed -i 's/DirectoryIndex.*/DirectoryIndex index.php index.html index.cgi index.pl index.xhtml index.htm/g' /etc/apache2/mods-enabled/dir.conf
sudo systemctl restart apache2

# Генерация пароля для пользователя root базы данных MariaDB
MYSQL_ROOT_PASSWORD=$(openssl rand -base64 12)

sudo mysql <<MYSQL_SCRIPT
ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '$MYSQL_ROOT_PASSWORD';
FLUSH PRIVILEGES;
EXIT;
MYSQL_SCRIPT

# Установка WordPress, если не установлен
for i in {1..3}; do
  WORDPRESS_DB="wordpress$i"
  WORDPRESS_USER="wordpressuser$i"
  WORDPRESS_PASSWORD="password$i"

  if ! check_package_installed "wordpress"; then
      # Загрузка и установка WordPress
      cd /tmp
      wget https://wordpress.org/latest.tar.gz
      tar -xvzf latest.tar.gz
      sudo mv wordpress /var/www/html/wordpress$i
  fi

  # Настройка прав доступа к файлам WordPress
  sudo chown -R www-data:www-data /var/www/html/wordpress$i
  sudo chmod -R 755 /var/www/html/wordpress$i

  # Создание баз данных и пользователей для WordPress, если не созданы
  if ! check_package_installed "mysql-server"; then
      sudo mysql <<MYSQL_SCRIPT
      CREATE DATABASE $WORDPRESS_DB;
      CREATE USER '$WORDPRESS_USER'@'localhost' IDENTIFIED BY '$WORDPRESS_PASSWORD';
      GRANT ALL PRIVILEGES ON $WORDPRESS_DB.* TO '$WORDPRESS_USER'@'localhost';
      FLUSH PRIVILEGES;
      EXIT;
MYSQL_SCRIPT
  fi

  # Создание виртуального хоста Apache для WordPress
  if [ ! -f "/etc/apache2/sites-available/wordpress$i.conf" ]; then
      sudo tee /etc/apache2/sites-available/wordpress$i.conf > /dev/null <<EOT
<VirtualHost *:808$i>
    ServerAdmin webmaster@localhost
    DocumentRoot /var/www/html/wordpress$i

    <Directory /var/www/html/wordpress$i>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog ${APACHE_LOG_DIR}/wordpress$i_error.log
    CustomLog ${APACHE_LOG_DIR}/wordpress$i_access.log combined
</VirtualHost>
EOT
EOT
  fi
  
    # Редактирование конфигурационного файла wp-config.php
  sudo cp /var/www/html/wordpress$i/wp-config-sample.php /var/www/html/wordpress$i/wp-config.php
  sudo sed -i "s/database_name_here/$WORDPRESS_DB/" /var/www/html/wordpress$i/wp-config.php
  sudo sed -i "s/username_here/$WORDPRESS_USER/" /var/www/html/wordpress$i/wp-config.php
  sudo sed -i "s/password_here/$WORDPRESS_PASSWORD/" /var/www/html/wordpress$i/wp-config.php
  sudo sed -i "s/localhost/localhost/" /var/www/html/wordpress$i/wp-config.php

  sudo a2ensite wordpress$i.conf
done

# Перезагрузка Apache
sudo a2dissite 000-default.conf
sudo systemctl restart apache2

# Установка и настройка Nginx, если не установлены
if ! check_package_installed "nginx"; then
    sudo apt install -y nginx
fi

# Создание конфигурации для проксирования Nginx
if [ ! -f "/etc/nginx/sites-available/wordpress_proxy" ]; then
    sudo tee /etc/nginx/sites-available/wordpress_proxy > /dev/null <<EOT
server {
    listen 80;
    server_name example.com; # Замените на ваш домен

    location /wordpress1 {
        proxy_pass http://127.0.0.1:8081/; # Порт Apache для первого экземпляра
        proxy_set_header Host "$host";
        proxy_set_header X-Real-IP "$remote_addr";
    }

    location /wordpress2 {
        proxy_pass http://127.0.0.1:8082/; # Порт Apache для второго экземпляра
        proxy_set_header Host "$host";
        proxy_set_header X-Real-IP "$remote_addr";
    }

    location /wordpress3 {
        proxy_pass http://127.0.0.1:8083/; # Порт Apache для третьего экземпляра
        proxy_set_header Host "$host";
        proxy_set_header X-Real-IP "$remote_addr";
    }

    
}
EOT
fi

sudo ln -s /etc/nginx/sites-available/wordpress_proxy /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl restart nginx

echo "Установка и настройка WordPress и Nginx завершены!"
echo "Пароль для пользователя root базы данных MariaDB: $MYSQL_ROOT_PASSWORD"
