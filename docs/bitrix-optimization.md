# Рекомендации по оптимизации Битрикс и Битрикс24

## Обзор

Данный документ содержит комплексные рекомендации по оптимизации производительности и безопасности установок Битрикс24 и Bitrix Framework, основанные на анализе официальной документации и лучших практиках.

## Системные требования и настройки

### Операционная система

**Рекомендуемые дистрибутивы:**
- Ubuntu 20.04+ LTS
- CentOS 8+ / RHEL 8+
- Debian 11+

**Минимальные требования:**
- CPU: 2 ядра (рекомендуется 4+)
- RAM: 4GB (рекомендуется 8GB+)
- Диск: 50GB SSD (рекомендуется 100GB+)

### Ядро Linux

**Критичные параметры sysctl:**

```bash
# Память и виртуальная память
vm.swappiness = 10                    # Снижение использования swap
vm.dirty_ratio = 15                   # Процент грязных страниц для записи
vm.dirty_background_ratio = 5         # Фоновое сброс грязных страниц
vm.overcommit_memory = 1              # Разрешить overcommit памяти
vm.max_map_count = 262144             # Максимум memory maps

# Сеть
net.core.somaxconn = 1024             # Размер очереди подключений
net.core.netdev_max_backlog = 5000    # Размер очереди сетевых пакетов
net.ipv4.tcp_max_syn_backlog = 2048   # Размер очереди SYN запросов
net.ipv4.tcp_fin_timeout = 30         # Таймаут закрытия соединения
net.ipv4.tcp_tw_reuse = 1             # Переиспользование TIME_WAIT сокетов

# Файловая система
fs.file-max = 2097152                 # Максимум открытых файлов
fs.inotify.max_user_watches = 524288  # Максимум отслеживаемых файлов
```

## Настройки PHP

### Основные параметры

```ini
; Память и выполнение
memory_limit = 512M                   # Лимит памяти (минимум 256M)
max_execution_time = 300              # Максимальное время выполнения
max_input_time = 300                  # Максимальное время обработки ввода
max_input_vars = 10000                # Максимум переменных ввода

; Загрузка файлов
upload_max_filesize = 1024M           # Максимальный размер загружаемого файла
post_max_size = 1024M                 # Максимальный размер POST данных
max_file_uploads = 50                 # Максимум файлов за одну загрузку

; Сессии
session.gc_maxlifetime = 1440         # Время жизни сессии (24 минуты)
session.gc_probability = 1            # Вероятность очистки сессий
session.gc_divisor = 1000             # Делитель для вероятности очистки

; Безопасность
expose_php = Off                      # Скрыть информацию о PHP
allow_url_fopen = Off                 # Запретить открытие удаленных URL
allow_url_include = Off               # Запретить включение удаленных файлов
display_errors = Off                  # Скрыть ошибки в продакшене
log_errors = On                       # Логировать ошибки
error_log = /var/log/php_errors.log   # Путь к логу ошибок
```

### OPcache настройки

```ini
; Включение OPcache
opcache.enable = 1
opcache.enable_cli = 1

; Память и файлы
opcache.memory_consumption = 256       # Память для OPcache (MB)
opcache.interned_strings_buffer = 16  # Буфер для интернированных строк
opcache.max_accelerated_files = 20000 # Максимум файлов в кеше
opcache.max_wasted_percentage = 10    # Максимальный процент отходов

; Поведение
opcache.validate_timestamps = 0       # Не проверять время изменения файлов
opcache.revalidate_freq = 0           # Частота перепроверки файлов
opcache.save_comments = 0             # Не сохранять комментарии
opcache.enable_file_override = 1      # Разрешить переопределение файлов

; Очистка
opcache.max_file_size = 0             # Максимальный размер файла для кеширования
opcache.force_restart_timeout = 180   # Таймаут принудительного перезапуска
```

### PHP-FPM настройки

```ini
; Основные настройки
pm = dynamic                          # Режим управления процессами
pm.max_children = 50                  # Максимум дочерних процессов
pm.start_servers = 10                 # Количество процессов при запуске
pm.min_spare_servers = 5              # Минимум свободных процессов
pm.max_spare_servers = 15             # Максимум свободных процессов
pm.max_requests = 1000                # Максимум запросов на процесс

; Таймауты
request_terminate_timeout = 300       # Таймаут завершения запроса
request_slowlog_timeout = 10          # Таймаут для медленных запросов

; Логирование
slowlog = /var/log/php-fpm-slow.log   # Лог медленных запросов
```

## Настройки MySQL/MariaDB

### Основные параметры

```ini
# Память
innodb_buffer_pool_size = 2G          # 70-80% от RAM
innodb_log_file_size = 256M           # Размер лог-файла
innodb_log_buffer_size = 64M          # Размер буфера лога

# Соединения
max_connections = 500                 # Максимум соединений
max_connect_errors = 100000           # Максимум ошибок соединения
connect_timeout = 10                  # Таймаут соединения

# Запросы
query_cache_type = 1                  # Включить кеш запросов
query_cache_size = 128M               # Размер кеша запросов
query_cache_limit = 2M                # Максимальный размер результата в кеше

# Временные таблицы
tmp_table_size = 256M                 # Размер временных таблиц в памяти
max_heap_table_size = 256M            # Максимальный размер heap таблиц

# Логирование
slow_query_log = 1                    # Включить лог медленных запросов
slow_query_log_file = /var/log/mysql/slow.log
long_query_time = 2                   # Минимальное время для медленного запроса
log_queries_not_using_indexes = 1     # Логировать запросы без индексов

# InnoDB
innodb_flush_log_at_trx_commit = 2    # Производительность vs надежность
innodb_flush_method = O_DIRECT        # Метод сброса данных
innodb_file_per_table = 1             # Отдельный файл для каждой таблицы
innodb_read_io_threads = 8            # Потоки чтения
innodb_write_io_threads = 8           # Потоки записи
```

### Оптимизация индексов

```sql
-- Анализ медленных запросов
SELECT * FROM mysql.slow_log ORDER BY start_time DESC LIMIT 10;

-- Поиск таблиц без индексов
SELECT 
    table_schema,
    table_name,
    table_rows,
    data_length,
    index_length
FROM information_schema.tables 
WHERE table_schema NOT IN ('information_schema', 'mysql', 'performance_schema')
AND index_length = 0
ORDER BY data_length DESC;

-- Анализ использования индексов
SELECT 
    table_schema,
    table_name,
    index_name,
    cardinality
FROM information_schema.statistics
WHERE table_schema NOT IN ('information_schema', 'mysql', 'performance_schema')
ORDER BY cardinality DESC;
```

## Настройки веб-сервера

### Nginx конфигурация

```nginx
# Основные настройки
worker_processes auto;                # Количество worker процессов
worker_connections 2048;              # Максимум соединений на worker
worker_rlimit_nofile 65535;           # Лимит открытых файлов

# Оптимизация событий
events {
    use epoll;                        # Использовать epoll (Linux)
    multi_accept on;                  # Принимать несколько соединений
    worker_connections 2048;
}

# HTTP настройки
http {
    # Основные параметры
    sendfile on;                      # Использовать sendfile
    tcp_nopush on;                    # Оптимизация TCP
    tcp_nodelay on;                   # Отключить задержку Nagle
    keepalive_timeout 65;             # Таймаут keep-alive
    keepalive_requests 100;           # Максимум запросов на соединение
    
    # Буферы
    client_body_buffer_size 128k;     # Буфер тела запроса
    client_max_body_size 1024m;       # Максимальный размер тела запроса
    client_header_buffer_size 1k;     # Буфер заголовков
    large_client_header_buffers 4 4k; # Буферы для больших заголовков
    
    # Сжатие
    gzip on;                          # Включить gzip
    gzip_vary on;                     # Добавлять Vary заголовок
    gzip_min_length 1000;             # Минимальный размер для сжатия
    gzip_comp_level 6;                # Уровень сжатия
    gzip_types
        text/plain
        text/css
        text/xml
        text/javascript
        application/javascript
        application/xml+rss
        application/json;
    
    # Кеширование статики
    location ~* \.(jpg|jpeg|png|gif|ico|css|js|woff|woff2|ttf|svg)$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
        access_log off;
    }
    
    # Основная конфигурация для Битрикс
    location / {
        try_files $uri $uri/ /bitrix/urlrewrite.php$is_args$args;
    }
    
    location ~ \.php$ {
        fastcgi_pass unix:/var/run/php/php8.1-fpm.sock;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        include fastcgi_params;
        
        # Таймауты
        fastcgi_connect_timeout 60s;
        fastcgi_send_timeout 60s;
        fastcgi_read_timeout 60s;
        
        # Буферы
        fastcgi_buffer_size 128k;
        fastcgi_buffers 4 256k;
        fastcgi_busy_buffers_size 256k;
    }
}
```

### Apache конфигурация

```apache
# Основные настройки
ServerTokens Prod                     # Скрыть информацию о сервере
ServerSignature Off                   # Отключить подпись сервера

# Модули
LoadModule rewrite_module modules/mod_rewrite.so
LoadModule deflate_module modules/mod_deflate.so
LoadModule expires_module modules/mod_expires.so
LoadModule headers_module modules/mod_headers.so

# Производительность
KeepAlive On                          # Включить keep-alive
KeepAliveTimeout 5                    # Таймаут keep-alive
MaxKeepAliveRequests 100              # Максимум запросов на соединение

# Сжатие
<IfModule mod_deflate.c>
    AddOutputFilterByType DEFLATE text/plain
    AddOutputFilterByType DEFLATE text/html
    AddOutputFilterByType DEFLATE text/xml
    AddOutputFilterByType DEFLATE text/css
    AddOutputFilterByType DEFLATE application/xml
    AddOutputFilterByType DEFLATE application/xhtml+xml
    AddOutputFilterByType DEFLATE application/rss+xml
    AddOutputFilterByType DEFLATE application/javascript
    AddOutputFilterByType DEFLATE application/x-javascript
</IfModule>

# Кеширование
<IfModule mod_expires.c>
    ExpiresActive On
    ExpiresByType image/jpg "access plus 1 month"
    ExpiresByType image/jpeg "access plus 1 month"
    ExpiresByType image/gif "access plus 1 month"
    ExpiresByType image/png "access plus 1 month"
    ExpiresByType text/css "access plus 1 month"
    ExpiresByType application/pdf "access plus 1 month"
    ExpiresByType text/javascript "access plus 1 month"
    ExpiresByType application/javascript "access plus 1 month"
</IfModule>

# Rewrite правила для Битрикс
RewriteEngine On
RewriteCond %{REQUEST_FILENAME} !-f
RewriteCond %{REQUEST_FILENAME} !-l
RewriteCond %{REQUEST_FILENAME} !-d
RewriteRule ^(.*)$ /bitrix/urlrewrite.php [L,QSA]
```

## Кеширование

### Memcached

```ini
# Настройки Memcached
-m 512                                # Память для Memcached (MB)
-p 11211                              # Порт
-u memcached                          # Пользователь
-l 127.0.0.1                          # Привязка к интерфейсу
-c 1024                               # Максимум соединений
-t 4                                  # Количество потоков
```

**Интеграция с Битрикс:**

```php
// В .settings.php
'cache' => array(
    'value' => array(
        'type' => 'memcache',
        'memcache' => array(
            'host' => '127.0.0.1',
            'port' => '11211',
            'sid' => 'bitrix',
        ),
    ),
),
```

### Redis

```ini
# Настройки Redis
maxmemory 512mb                       # Максимальная память
maxmemory-policy allkeys-lru          # Политика вытеснения
save 900 1                            # Сохранение на диск
save 300 10
save 60 10000
```

**Интеграция с Битрикс:**

```php
// В .settings.php
'cache' => array(
    'value' => array(
        'type' => 'redis',
        'redis' => array(
            'host' => '127.0.0.1',
            'port' => '6379',
            'sid' => 'bitrix',
        ),
    ),
),
```

## Двухуровневая архитектура

### Front-end сервер (Nginx)

```nginx
# Основная конфигурация
upstream backend {
    server 192.168.1.10:8080 weight=3;
    server 192.168.1.11:8080 weight=2;
    server 192.168.1.12:8080 weight=1;
}

server {
    listen 80;
    server_name example.com;
    
    # Статические файлы
    location ~* \.(jpg|jpeg|png|gif|ico|css|js|woff|woff2|ttf|svg)$ {
        root /var/www/static;
        expires 1y;
        add_header Cache-Control "public, immutable";
        access_log off;
    }
    
    # Проксирование на backend
    location / {
        proxy_pass http://backend;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

### Back-end сервер (Apache + PHP-FPM)

```apache
# Виртуальный хост
<VirtualHost *:8080>
    DocumentRoot /home/bitrix/www
    ServerName example.com
    
    <Directory /home/bitrix/www>
        AllowOverride All
        Require all granted
    </Directory>
    
    # PHP-FPM
    ProxyPassMatch ^/(.*\.php)$ fcgi://127.0.0.1:9000/home/bitrix/www/$1
</VirtualHost>
```

## Мониторинг и диагностика

### Ключевые метрики

**Системные:**
- CPU usage < 80%
- Memory usage < 90%
- Disk I/O < 80%
- Load average < количество ядер

**Веб-сервер:**
- Response time < 200ms
- Error rate < 1%
- Active connections < 80% от максимума

**База данных:**
- Query time < 100ms
- Connections < 80% от максимума
- Cache hit ratio > 95%

### Инструменты мониторинга

```bash
# Системные ресурсы
htop
iotop
nethogs

# Веб-сервер
nginx -t                    # Проверка конфигурации
apache2ctl configtest       # Проверка конфигурации Apache

# База данных
mysqladmin status           # Статус MySQL
mysqladmin processlist      # Активные процессы

# PHP
php-fpm -t                  # Проверка конфигурации PHP-FPM
```

## Безопасность

### Основные меры

1. **Обновления**
   - Регулярно обновляйте систему и компоненты
   - Используйте только стабильные версии

2. **Права доступа**
   ```bash
   # Файлы настроек
   chmod 600 /home/bitrix/www/bitrix/.settings.php
   
   # Директории
   chmod 755 /home/bitrix/www
   chmod 777 /home/bitrix/www/bitrix/cache
   chmod 777 /home/bitrix/www/upload
   ```

3. **Firewall**
   ```bash
   # Разрешить только необходимые порты
   ufw allow 22/tcp    # SSH
   ufw allow 80/tcp    # HTTP
   ufw allow 443/tcp   # HTTPS
   ufw deny 3306/tcp   # MySQL (только локально)
   ```

4. **SSL/TLS**
   - Используйте только TLS 1.2+
   - Настройте HSTS
   - Используйте сильные шифры

### Аудит безопасности

```bash
# Проверка прав доступа
find /home/bitrix -type f -perm /022 -ls

# Поиск SUID/SGID файлов
find /home/bitrix -type f \( -perm -4000 -o -perm -2000 \) -ls

# Проверка world-writable файлов
find /home/bitrix -type f -perm -002 -ls
```

## Автоматизация

### Скрипты очистки

```bash
#!/bin/bash
# Очистка кеша Битрикс
find /home/bitrix -path "*/bitrix/cache/*" -type f -mtime +7 -delete
find /home/bitrix -path "*/bitrix/managed_cache/*" -type f -mtime +7 -delete
find /home/bitrix -path "*/bitrix/stack_cache/*" -type f -mtime +7 -delete

# Очистка логов
find /var/log -name "*.log" -mtime +30 -delete
find /var/log -name "*.gz" -mtime +90 -delete
```

### Cron задачи

```bash
# Ежедневная очистка кеша
0 2 * * * /usr/local/bin/bitrix-cache-cleanup.sh

# Еженедельная оптимизация базы данных
0 3 * * 0 /usr/local/bin/mysql-optimize.sh

# Ежемесячная очистка логов
0 4 1 * * /usr/local/bin/log-cleanup.sh
```

## Производительность

### Оптимизация запросов

1. **Индексы**
   - Создавайте индексы для часто используемых полей
   - Используйте составные индексы для сложных запросов
   - Регулярно анализируйте использование индексов

2. **Кеширование**
   - Включите кеширование на всех уровнях
   - Используйте CDN для статических файлов
   - Настройте браузерное кеширование

3. **Оптимизация кода**
   - Минимизируйте количество запросов к БД
   - Используйте lazy loading
   - Оптимизируйте изображения

### Масштабирование

1. **Вертикальное масштабирование**
   - Увеличьте RAM для увеличения буферов
   - Добавьте CPU для обработки запросов
   - Используйте SSD для ускорения I/O

2. **Горизонтальное масштабирование**
   - Настройте load balancer
   - Используйте репликацию БД
   - Разделите статику и динамику

## Заключение

Следование данным рекомендациям поможет значительно улучшить производительность и безопасность установок Битрикс24 и Bitrix Framework. Регулярно проводите аудит системы и корректируйте настройки в соответствии с изменяющимися требованиями.
