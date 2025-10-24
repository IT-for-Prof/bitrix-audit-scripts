# Требования к системе для Bitrix24 Audit Scripts

## Обзор

Этот документ описывает все требования к системе для корректной работы скриптов аудита Bitrix24.

## Критически важные локали

### Почему локали критичны?

Локали используются для корректного парсинга дат из различных источников:

1. **atopsar** - временные метки из бинарных логов atop
2. **sadf/sar** - CSV вывод sysstat с датами
3. **analyze_errors.sh** - даты из логов nginx/apache (monthnum в awk)
4. **date** - генерация временных меток

### Требуемые локали

- `en_US.UTF-8` - **обязательно** для парсинга английских дат/сообщений
- `ru_RU.UTF-8` - рекомендуется для корректного отображения русских дат

### Установка локалей

#### Debian/Ubuntu

```bash
# Установка локалей
sudo locale-gen en_US.UTF-8 ru_RU.UTF-8

# Проверка установки
locale -a | grep -E "(en_US|ru_RU)"
```

#### RHEL/CentOS

```bash
# Установка локалей
sudo localedef -i en_US -f UTF-8 en_US.UTF-8
sudo localedef -i ru_RU -f UTF-8 ru_RU.UTF-8

# Проверка установки
locale -a | grep -E "(en_US|ru_RU)"
```

#### Альтернативный способ (RHEL/CentOS)

```bash
# Редактирование /etc/locale.conf
echo "LANG=en_US.UTF-8" | sudo tee /etc/locale.conf
echo "LC_TIME=ru_RU.UTF-8" | sudo tee -a /etc/locale.conf

# Применение изменений
sudo localectl set-locale LANG=en_US.UTF-8
```

### Проверка локалей

```bash
# Проверка доступных локалей
locale -a

# Проверка текущих настроек
locale

# Тест парсинга дат
LANGUAGE=en_US.UTF-8 LC_TIME=ru_RU.UTF-8 date -d "2024-01-15 14:30:00" +%Y-%m-%d
```

## Обязательные утилиты

### Bash и основные утилиты

- **bash** >= 4.0
- **coreutils**: cat, date, find, grep, sed, awk, sort, head, tail, wc, tr, cut, mktemp, mkdir, hostname
- **tar** - для создания архивов
- **gzip** - для сжатия архивов
- **procps-ng**: ps, top

### Установка (Debian/Ubuntu)

```bash
sudo apt-get update
sudo apt-get install bash coreutils tar gzip procps-ng
```

### Установка (RHEL/CentOS)

```bash
sudo yum install bash coreutils tar gzip procps-ng
# или для CentOS 8+
sudo dnf install bash coreutils tar gzip procps-ng
```

## Опциональные утилиты (по модулям)

### Nginx модуль

- **nginx** - веб-сервер
- **curl** - HTTP клиент
- **openssl** - SSL утилиты
- **nc/ncat** - сетевые утилиты
- **ss/netstat** - сетевые утилиты
- **lsof** - утилита для работы с файлами
- **tree** - отображение структуры каталогов

### Установка (Debian/Ubuntu)

```bash
sudo apt-get install nginx curl openssl netcat-openbsd iproute2 lsof tree
```

### Установка (RHEL/CentOS)

```bash
sudo yum install nginx curl openssl nc iproute lsof tree
```

### Apache модуль

- **apache2/httpd** - веб-сервер
- **apachectl** - управление Apache

### Установка (Debian/Ubuntu)

```bash
sudo apt-get install apache2
```

### Установка (RHEL/CentOS)

```bash
sudo yum install httpd
```

### MySQL модуль

- **mysql** - клиент MySQL
- **mysqladmin** - административные утилиты MySQL
- **percona-toolkit** - набор утилит для анализа и оптимизации MySQL (рекомендуется)
  - `pt-query-digest` - анализ slow query log
  - `pt-mysql-summary` - сводка по серверу MySQL
  - `pt-duplicate-key-checker` - поиск дублирующихся индексов
  - `pt-variable-advisor` - рекомендации по конфигурации
  - `pt-index-usage` - статистика использования индексов

### Установка (Debian/Ubuntu)

```bash
sudo apt-get install mysql-client percona-toolkit
```

### Установка (RHEL/CentOS)

```bash
sudo yum install mysql percona-toolkit
```

### Установка Percona Toolkit вручную

Если пакет недоступен в репозитории:

```bash
# Скачать последнюю версию
wget https://www.percona.com/downloads/percona-toolkit/LATEST/binary/tarball/percona-toolkit-latest.tar.gz

# Распаковать
tar xzf percona-toolkit-latest.tar.gz

# Установить зависимости Perl
sudo apt-get install libdbi-perl libdbd-mysql-perl  # Debian/Ubuntu
sudo yum install perl-DBI perl-DBD-MySQL            # RHEL/CentOS

# Скопировать утилиты в системный каталог
sudo cp percona-toolkit-*/bin/* /usr/local/bin/
```

### PHP модуль

- **php** - интерпретатор PHP
- **php-fpm** - FastCGI Process Manager
- **composer** - менеджер пакетов PHP (опционально)

### Установка (Debian/Ubuntu)

```bash
sudo apt-get install php php-fpm composer
```

### Установка (RHEL/CentOS)

```bash
sudo yum install php php-fpm composer
```

### Redis модуль

- **redis-cli** - клиент Redis

### Установка (Debian/Ubuntu)

```bash
sudo apt-get install redis-tools
```

### Установка (RHEL/CentOS)

```bash
sudo yum install redis
```

### Системный модуль

- **systemctl** - управление systemd
- **journalctl** - просмотр журналов systemd
- **iostat** - статистика I/O
- **vmstat** - статистика виртуальной памяти
- **ethtool** - утилиты для работы с сетевыми интерфейсами
- **smartctl** - утилиты SMART
- **findmnt** - утилиты для работы с монтированием
- **numactl** - утилиты NUMA
- **chronyc/ntpq** - клиенты синхронизации времени
- **slabtop** - утилиты для работы с slab

### Установка (Debian/Ubuntu)

```bash
sudo apt-get install systemd sysstat ethtool smartmontools util-linux numactl chrony slabtop
```

### Установка (RHEL/CentOS)

```bash
sudo yum install systemd sysstat ethtool smartmontools util-linux numactl chrony slabtop
```

### ATOP модуль

- **atop** - системный монитор
- **atopsar** - утилита для работы с логами atop

### Установка (Debian/Ubuntu)

```bash
sudo apt-get install atop
```

### Установка (RHEL/CentOS)

```bash
sudo yum install atop
```

### SAR модуль

- **sar** - системный репортер активности
- **sadf** - форматтер данных SAR

### Установка (Debian/Ubuntu)

```bash
sudo apt-get install sysstat
```

### Установка (RHEL/CentOS)

```bash
sudo yum install sysstat
```

### Cron модуль

- **crontab** - утилиты cron

### Установка (Debian/Ubuntu)

```bash
sudo apt-get install cron
```

### Установка (RHEL/CentOS)

```bash
sudo yum install cronie
```

## Системные требования

### Минимальные требования

- **OS**: Linux (kernel 3.x+)
- **Architecture**: x86_64, i386
- **RAM**: 512 MB (рекомендуется 1 GB+)
- **Disk**: 100 MB свободного места
- **Network**: доступ к интернету для установки пакетов

### Рекомендуемые требования

- **OS**: Ubuntu 18.04+, CentOS 7+, RHEL 7+
- **Architecture**: x86_64
- **RAM**: 2 GB+
- **Disk**: 1 GB+ свободного места
- **Network**: стабильное подключение к интернету

## Права доступа

### Root права (ОБЯЗАТЕЛЬНО для production)

**КРИТИЧНО**: Для полноценного аудита в production-среде **ОБЯЗАТЕЛЬНО** нужны root-права!

Скрипты требуют root права для:
- Доступа к системным логам (`/var/log/`)
- Чтения конфигурационных файлов (`/etc/`)
- Выполнения системных команд (`smartctl`, `dmidecode`)
- Создания архивов в системных каталогах
- Полного анализа процессов и сети

### Альтернатива: sudo

Если root права недоступны, используйте sudo:

```bash
sudo ./run_all_audits.sh --all
```

### Настройка sudo для автоматизации

Для автоматического запуска через cron или systemd создайте sudo-правило:

```bash
# Создать файл sudo-правила
sudo visudo -f /etc/sudoers.d/bitrix-audit

# Добавить правило (замените username на вашего пользователя)
username ALL=(ALL) NOPASSWD: /root/Audit-Bitrix24/run_all_audits.sh
```

### Примеры для cron/systemd

**Cron (запуск от root):**
```bash
# Добавить в crontab root
0 2 * * * /root/Audit-Bitrix24/run_all_audits.sh --all
```

**Cron через sudo (если запускается от пользователя):**
```bash
# Добавить в crontab пользователя
0 2 * * * sudo /root/Audit-Bitrix24/run_all_audits.sh --all
```

**Systemd-сервис:**
```ini
# /etc/systemd/system/bitrix-audit.service
[Unit]
Description=Bitrix24 Daily Audit
After=network.target

[Service]
Type=oneshot
User=root
ExecStart=/root/Audit-Bitrix24/run_all_audits.sh --all

[Install]
WantedBy=multi-user.target
```

### Настройка sudo

Для автоматизации добавьте в `/etc/sudoers`:

```
# Разрешить выполнение скриптов аудита без пароля
audit_user ALL=(ALL) NOPASSWD: /path/to/Audit-Bitrix24/*
```

## Автоматическая установка и настройка

### Быстрый старт

Для автоматической проверки и установки всех недостающих пакетов:

```bash
sudo ./check_requirements.sh --install
```

Для неинтерактивной установки (без подтверждений):

```bash
sudo ./check_requirements.sh --install --non-interactive
```

### Детальная настройка мониторинга

Для автоматической установки и настройки только инструментов мониторинга:

```bash
sudo ./setup_monitoring.sh
```

Опции setup_monitoring.sh:
- `--non-interactive` - запуск без интерактивных подтверждений
- `--force` - принудительная переустановка
- `--verbose` - подробный вывод

### Что устанавливается автоматически

#### Основные пакеты (для всех дистрибутивов):
- **jq** - JSON парсер для работы с API
- **curl, wget** - HTTP клиенты для API запросов
- **lynis** - комплексный аудит безопасности
- **tuned** - оптимизация производительности системы
- **mysqltuner** - анализатор конфигурации MySQL
- **percona-toolkit** - расширенные инструменты для MySQL
- **gnuplot** - генерация графиков
- **sysbench** - бенчмаркинг

#### Инструменты мониторинга:
- **sysstat** - системный монитор (sar, iostat, vmstat)
  - Настройка: 30-секундные интервалы, хранение 7 дней
- **atop** - расширенный системный монитор
  - Настройка: 30-секундные интервалы, хранение 7 дней
- **psacct/acct** - учет процессов

#### Особенности установки Percona Toolkit:

**Debian/Ubuntu:**
```bash
apt-get install percona-toolkit
```

**RHEL-family (AlmaLinux/Rocky/CentOS/RHEL):**
```bash
# Автоматическая установка репозитория Percona
dnf install -y https://repo.percona.com/yum/percona-release-latest.noarch.rpm
percona-release enable tools release
dnf install -y percona-toolkit
```

Для старых дистрибутивов (без dnf) автоматически используется yum.

### Проверка безопасности и уязвимостей

При автоматической установке выполняется:

1. **Проверка уязвимых пакетов** перед установкой
2. **Установка инструментов безопасности**:
   - lynis - комплексный аудит безопасности
   - debsecan - сканер CVE для Debian/Ubuntu
   - dnf-plugin-security / yum-plugin-security - для RHEL-family
3. **Применение обновлений безопасности** после установки пакетов

#### Debian/Ubuntu:
```bash
# Проверка уязвимостей
apt list --upgradable | grep -i security
debsecan

# Применение обновлений безопасности
apt-get upgrade --security
```

#### RHEL-family (AlmaLinux/Rocky/CentOS):
```bash
# Проверка уязвимостей
dnf updateinfo list security

# Применение обновлений безопасности  
dnf update --security
```

#### Автоматическая проверка:

Скрипты аудита автоматически проверяют уязвимости через:
- `collect_system_info.sh` - анализирует установленные пакеты
- Функции: `check_vulnerable_packages_apt()`, `check_vulnerable_packages_yum()`
- Интеграция с debsecan, dnf updateinfo, yum-plugin-security

#### Рекомендации:

- Регулярно запускайте полный аудит: `./run_all_audits.sh --all`
- Настройте автоматические обновления безопасности
- Используйте lynis для глубокого анализа: `lynis audit system`
- Мониторьте CVE базы данных для критичных компонентов

### Проверка установки

После установки проверьте требования:

```bash
./check_requirements.sh --verbose
```

Для проверки конкретного модуля:

```bash
./check_requirements.sh --module tools --verbose
./check_requirements.sh --module security --verbose
```

## Проверка требований

### Автоматическая проверка

```bash
./check_requirements.sh
```

### Проверка конкретного модуля

```bash
./check_requirements.sh --module nginx
```

### Подробная проверка

```bash
./check_requirements.sh --verbose
```

## Troubleshooting

### Проблемы с локалями

1. **Ошибка парсинга дат**
   ```bash
   # Проверьте доступные локали
   locale -a
   
   # Установите недостающие локали
   sudo locale-gen en_US.UTF-8 ru_RU.UTF-8
   ```

2. **Неправильное отображение дат**
   ```bash
   # Проверьте текущие настройки
   locale
   
   # Установите правильные настройки
   export LANGUAGE=en_US.UTF-8
   export LC_TIME=ru_RU.UTF-8
   ```

3. **Ошибки в awk**
   ```bash
   # Убедитесь, что LC_NUMERIC=C
   export LC_NUMERIC=C
   ```

### Проблемы с правами доступа

1. **Permission denied**
   ```bash
   # Запускайте от root
   sudo ./run_all_audits.sh --all
   ```

2. **Недоступные файлы**
   ```bash
   # Проверьте права доступа
   ls -la /var/log/nginx/
   ls -la /etc/nginx/
   ```

### Проблемы с зависимостями

1. **Команда не найдена**
   ```bash
   # Установите недостающие пакеты
   sudo apt-get install package_name
   # или
   sudo yum install package_name
   ```

2. **Версия bash**
   ```bash
   # Проверьте версию bash
   bash --version
   
   # Требуется bash >= 4.0
   ```

## Примеры установки

### Полная установка (Debian/Ubuntu)

```bash
# Обновление системы
sudo apt-get update

# Установка основных пакетов
sudo apt-get install bash coreutils tar gzip procps-ng

# Установка веб-серверов
sudo apt-get install nginx apache2

# Установка баз данных
sudo apt-get install mysql-client redis-tools percona-toolkit

# Установка PHP
sudo apt-get install php php-fpm composer

# Установка системных утилит
sudo apt-get install systemd sysstat ethtool smartmontools util-linux numactl chrony slabtop

# Установка мониторинга
sudo apt-get install atop

# Установка инструментов безопасности (опционально)
sudo apt-get install lynis debsecan

# Установка cron
sudo apt-get install cron

# Установка локалей
sudo locale-gen en_US.UTF-8 ru_RU.UTF-8

# Проверка установки
./check_requirements.sh --verbose
```

### Полная установка (RHEL/CentOS)

```bash
# Обновление системы
sudo yum update

# Установка основных пакетов
sudo yum install bash coreutils tar gzip procps-ng

# Установка веб-серверов
sudo yum install nginx httpd

# Установка баз данных
sudo yum install mysql redis percona-toolkit

# Установка PHP
sudo yum install php php-fpm composer

# Установка системных утилит
sudo yum install systemd sysstat ethtool smartmontools util-linux numactl chrony slabtop

# Установка мониторинга
sudo yum install atop

# Установка инструментов безопасности (опционально)
sudo yum install lynis yum-plugin-security

# Установка cron
sudo yum install cronie

# Установка локалей
sudo localedef -i en_US -f UTF-8 en_US.UTF-8
sudo localedef -i ru_RU -f UTF-8 ru_RU.UTF-8

# Проверка установки
./check_requirements.sh --verbose
```

## Инструменты безопасности (опциональные)

Для расширенного анализа безопасности рекомендуется установить дополнительные инструменты:

### Для Debian/Ubuntu:
```bash
sudo apt install lynis debsecan
```

### Для RHEL/CentOS/AlmaLinux/Rocky Linux:
```bash
sudo dnf install lynis yum-plugin-security
# или для CentOS 7:
sudo yum install lynis yum-plugin-security
```

### Описание инструментов:

- **lynis** - Комплексный инструмент аудита безопасности системы (для всех дистрибутивов)
- **debsecan** - Сканер уязвимостей для Debian/Ubuntu (проверяет CVE) - только для Debian/Ubuntu
- **yum-plugin-security** - Плагин для yum/dnf для проверки обновлений безопасности - только для RHEL-семейства (CentOS, AlmaLinux, Rocky Linux)

Примечание: В современных версиях (dnf) функционал yum-plugin-security встроен в dnf updateinfo.

### Доступ к API endoflife.date

Скрипт может использовать API endoflife.date для получения актуальной информации о EOL статусе дистрибутивов. Для этого требуется:

- Доступ к интернету
- curl или wget (обычно уже установлены)
- jq (опционально, для лучшего парсинга JSON)

Если API недоступен, скрипт автоматически переключится на локальную базу данных EOL дат.

## Заключение

Соблюдение всех требований критически важно для корректной работы скриптов аудита. Особое внимание следует уделить настройке локалей, так как они напрямую влияют на парсинг дат и корректность анализа данных.

При возникновении проблем используйте скрипт `check_requirements.sh` для диагностики и следуйте рекомендациям по устранению неполадок.
