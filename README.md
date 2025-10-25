# Bitrix24 Audit Scripts

Комплексный набор скриптов для аудита производительности, проблем и узких мест VPS с окружением Bitrix24.

## Описание проекта

Этот проект содержит набор bash-скриптов для комплексного аудита серверов с установленным Bitrix24. Скрипты собирают информацию о производительности системы, анализируют логи ошибок, проверяют конфигурации сервисов и генерируют детальные отчеты.

## Архитектура

Проект состоит из следующих компонентов:

- **audit_common.sh** - общие функции и настройки локалей
- **collect_*.sh** - скрипты сбора данных по различным компонентам
- **analyze_*.sh** - скрипты анализа логов ошибок
- **run_all_audits.sh** - единый оркестратор для запуска всех аудитов
- **check_requirements.sh** - скрипт проверки зависимостей

## Быстрый старт

### 1. Проверка требований

```bash
./check_requirements.sh
```

### 2. Запуск полного аудита

```bash
./run_all_audits.sh --all
```

### 3. Запуск отдельных модулей

```bash
./run_all_audits.sh --nginx --mysql --php
./run_all_audits.sh --security  # Новый модуль аудита безопасности
```

## Требования к системе

### Обязательные утилиты

- bash >= 4.0
- coreutils (cat, date, find, grep, sed, awk, sort, head, tail, wc, tr, cut, mktemp, mkdir, hostname)
- tar, gzip
- procps-ng (ps, top)

### Опциональные (по модулям)

- **nginx**: nginx, curl, openssl, nc/ncat, ss/netstat, lsof, tree
- **apache**: apache2/httpd, apachectl
- **mysql**: mysql, mysqladmin
- **php**: php, php-fpm, composer (опц.)
- **redis**: redis-cli
- **system**: systemctl, journalctl, iostat, vmstat, lsof, ss, ethtool, smartctl, findmnt, numactl, chronyc/ntpq, slabtop
- **atop**: atop, atopsar
- **sar**: sar, sadf (пакет sysstat)
- **security**: lynis, auditctl, ausearch, getenforce, aa-status, fail2ban-client

### Системные требования

- Linux kernel 3.x+
- Root права (рекомендуется) или sudo для полного доступа

## Права доступа и требования

### Требование root для продакшена

**ВАЖНО**: Для полноценного аудита в production-среде **ОБЯЗАТЕЛЬНО** нужны root-права!

### Команда запуска

```bash
# Полный аудит (рекомендуется)
sudo ./run_all_audits.sh --all

# Или через sudo для пользователя
sudo ./run_all_audits.sh --all
```

### Настройка безопасного sudo для автоматизации

Для автоматического запуска через cron или systemd создайте sudo-правило:

```bash
# Создать файл sudo-правила
sudo visudo -f /etc/sudoers.d/bitrix-audit

# Добавить правило (замените username на вашего пользователя)
username ALL=(ALL) NOPASSWD: /root/Audit-Bitrix24/run_all_audits.sh
```

### Что недоступно без root

Без root-прав скрипты не смогут получить доступ к:

- **Логи**: `/var/log/nginx/`, `/var/log/apache2/`, `/var/log/mysql/`
- **Конфигурации**: `/etc/nginx/`, `/etc/apache2/`, `/etc/mysql/`
- **Системные команды**: `smartctl`, `dmidecode`, `lscpu`
- **Процессы**: полная информация о процессах и их ресурсах
- **Сеть**: детальная информация о сетевых соединениях

### Проверка текущих прав

```bash
# Проверить права доступа
./check_requirements.sh --module permissions

# Или запустить полную проверку
./check_requirements.sh
```

### Примеры автоматизации с root

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

## Критически важные локали

**ВНИМАНИЕ**: Локали критически важны для корректной работы скриптов!

### Почему нужны локали?

Локали используются для корректного парсинга дат из:
1. **atopsar** - временные метки из бинарных логов atop
2. **sadf/sar** - CSV вывод sysstat с датами
3. **analyze_errors.sh** - даты из логов nginx/apache (monthnum в awk)
4. **date** - генерация временных меток

### Требуемые локали

- `en_US.UTF-8` - **обязательно** для парсинга английских дат/сообщений
- `ru_RU.UTF-8` - рекомендуется для корректного отображения русских дат

### Установка локалей

**Debian/Ubuntu:**
```bash
sudo locale-gen en_US.UTF-8 ru_RU.UTF-8
```

**RHEL/CentOS:**
```bash
sudo localedef -i en_US -f UTF-8 en_US.UTF-8
sudo localedef -i ru_RU -f UTF-8 ru_RU.UTF-8
```

### Проверка локалей

```bash
locale -a | grep -E "(en_US|ru_RU)"
```

## Структура проекта

```
Audit-Bitrix24/
├── audit_common.sh              # Общие функции и настройки локалей
├── collect_nginx.sh              # Сбор данных nginx
├── collect_apache.sh             # Сбор данных apache
├── collect_mysql.sh              # Сбор данных mysql
├── collect_php.sh                # Сбор данных php
├── collect_redis.sh              # Сбор данных redis
├── collect_bitrix.sh             # Сбор данных Битрикс (кеш, настройки)
├── collect_system_info.sh        # Сбор системной информации
├── collect_atop.sh               # Сбор данных atop
├── collect_sar.sh                # Сбор данных sar
├── collect_cron.sh               # Сбор данных cron
├── collect_security.sh           # Аудит безопасности системы
├── analyze_nginx_errors.sh       # Анализ логов ошибок nginx
├── analyze_apache_errors.sh      # Анализ логов ошибок apache
├── analyze_and_recommend.sh      # Анализ и генерация рекомендаций
├── run_all_audits.sh             # Единый оркестратор
├── check_requirements.sh         # Проверка зависимостей
├── audit.conf.example            # Пример конфигурации
├── Makefile                      # Сборка и проверка
├── README.md                     # Этот файл
├── REQUIREMENTS.md               # Детальные требования
├── CHANGELOG.md                  # История изменений
└── docs/                         # Документация модулей
    ├── nginx-audit.md
    ├── apache-audit.md
    ├── mysql-audit.md
    ├── php-audit.md
    ├── redis-audit.md
    ├── bitrix-audit.md           # Документация модуля Битрикс
    ├── bitrix-optimization.md    # Рекомендации по оптимизации Битрикс
    ├── system-audit.md
    ├── performance-audit.md
    ├── error-analysis.md
    └── locales-and-dates.md
```

## Использование оркестратора

### Основные команды

```bash
# Запуск всех модулей
./run_all_audits.sh --all

# Запуск только nginx и mysql
./run_all_audits.sh --nginx --mysql

# Запуск только модуля Битрикс
./run_all_audits.sh --bitrix

# Запуск в параллельном режиме
./run_all_audits.sh --parallel

# Запуск с конфигурационным файлом
./run_all_audits.sh --config audit.conf
```

### Опции

- `--all` - запуск всех доступных модулей (по умолчанию)
- `--nginx` - запуск только nginx аудита
- `--apache` - запуск только apache аудита
- `--mysql` - запуск только mysql аудита
- `--php` - запуск только php аудита
- `--redis` - запуск только redis аудита
- `--bitrix` - запуск только аудита Битрикс (кеш, настройки)
- `--system` - запуск только системного аудита
- `--security` - запуск только аудита безопасности
- `--atop` - запуск только atop аудита
- `--sar` - запуск только sar аудита
- `--cron` - запуск только cron аудита
- `--analyze-errors` - запуск только анализа ошибок
- `--parallel` - параллельный запуск модулей
- `--sequential` - последовательный запуск модулей (по умолчанию)
- `--config FILE` - загрузка конфигурации из файла
- `--help` - справка

## Использование отдельных модулей

### Nginx аудит

```bash
./collect_nginx.sh
# или
./run_nginx_audit.sh
```

### Apache аудит

```bash
./collect_apache.sh
```

### MySQL аудит

```bash
./collect_mysql.sh
```

### PHP аудит

```bash
./collect_php.sh
```

### Redis аудит

```bash
./collect_redis.sh
```

### Битрикс аудит

```bash
# Полный анализ (настройки + кеш)
./collect_bitrix.sh

# Только анализ кеша
./collect_bitrix.sh --cache-only

# Только анализ настроек
./collect_bitrix.sh --settings-only

# Подробный вывод
./collect_bitrix.sh --verbose
```

### Аудит безопасности

```bash
# Полный аудит безопасности
sudo ./collect_security.sh

# Аудит с кастомными настройками
SECURITY_CHECK_LYNIS=0 SECURITY_AUTH_LOG_DAYS=60 sudo ./collect_security.sh
```

**Анализируемые компоненты:**
- Пользователи и аутентификация (/etc/passwd, /etc/shadow, /etc/group)
- Sudo конфигурация (/etc/sudoers, /etc/sudoers.d/*)
- SSH безопасность (sshd_config, SSH-ключи пользователей)
- Файловые права (SUID/SGID, world-writable, orphaned files)
- SELinux/AppArmor статус и конфигурация
- Auditd система аудита Linux
- Journald критичные события
- Kernel параметры безопасности
- Lynis интеграция (если установлен)
- Пакеты безопасности

### Системный аудит

```bash
./collect_system_info.sh
```

**Новые возможности анализа безопасности:**

- **Анализ версии ОС и EOL статуса** - проверка актуальности операционной системы
- **Анализ уязвимостей пакетов** - поиск критичных обновлений безопасности
- **Расширенный анализ фаервола** - детальная проверка UFW/firewalld/iptables
- **Проверка открытых портов** - анализ безопасности сетевых сервисов
- **Bitrix24-специфичные проверки** - рекомендации по безопасности для Bitrix24

**Примеры вывода:**

```
==== Информация об операционной системе ====
Дистрибутив: Ubuntu 22.04.3 LTS
Версия: 22.04
Кодовое имя: jammy
Версия ядра: 5.15.0-89-generic
Архитектура: x86_64

==== Статус поддержки (End of Life) ====
Тип поддержки: LTS
Поддержка до: 2032-04-21
Описание: Long Term Support
Источник данных: локальная база данных (дата проверки: 2025-01-15)

[OK] Операционная система находится в активной поддержке (2557 дней до EOL)

==== Анализ уязвимостей установленных пакетов ====
Метод проверки: apt (native)
Все пакеты актуальны

==== Расширенный анализ безопасности фаервола ====
Тип: UFW
Статус: активен
Политика по умолчанию: deny (incoming), allow (outgoing)

Активные правила:
  1. 22/tcp (SSH) - ALLOW from anywhere [OK] SSH защищен
  2. 80/tcp (HTTP) - ALLOW from anywhere [OK] HTTP открыт
  3. 443/tcp (HTTPS) - ALLOW from anywhere [OK] HTTPS открыт
  4. 3306/tcp (MySQL) - ALLOW from anywhere [WARN] MySQL открыт наружу!

Анализ открытых портов на безопасность:
Открытые порты:
  - 22/tcp (SSH) [OK]
  - 80/tcp (HTTP) [OK]
  - 443/tcp (HTTPS) [OK]
  - 3306/tcp (MySQL) [WARN] Должен быть доступен только локально

Рекомендации по настройке фаервола:
  [WARN] MySQL порт 3306 открыт:
    • Ограничьте доступ: sudo ufw allow from 10.0.0.0/8 to any port 3306
    • Или закройте: sudo ufw delete allow 3306/tcp
```

### Настройка мониторинга

```bash
# Автоматическая установка и настройка инструментов мониторинга
make setup-monitoring

# Или напрямую
./setup_monitoring.sh

# Интерактивная настройка
./setup_monitoring.sh --non-interactive

# Принудительная перенастройка
./setup_monitoring.sh --force --verbose
```

**Что настраивается:**

- **sysstat** - сбор статистики системы (sar, iostat, vmstat)
- **atop** - продвинутый мониторинг системы
- **sysbench** - инструмент бенчмаркинга
- **psacct/acct** - учет процессов

**Конфигурация:**

- Интервал сбора данных: 30 секунд
- Хранение данных: 7 дней
- Автоматический запуск сервисов
- Резервные копии конфигураций

### Анализ производительности

```bash
# ATOP анализ
ATOP_FULL_DAY=1 ./collect_atop.sh

# SAR анализ
SAR_FULL_DAY=1 SAR_DAYS=7 ./collect_sar.sh
```

### Анализ ошибок

```bash
# Анализ ошибок nginx
ERROR_ANALYSIS_DAYS=7 ./analyze_nginx_errors.sh

# Анализ ошибок apache
ERROR_ANALYSIS_DAYS=7 ./analyze_apache_errors.sh
```

## Конфигурация

### Создание конфигурационного файла

```bash
cp audit.conf.example audit.conf
# Отредактируйте audit.conf под ваши нужды
```

### Основные параметры

```bash
# Какие модули включены
ENABLE_NGINX=1
ENABLE_APACHE=1
ENABLE_MYSQL=1
ENABLE_PHP=1
ENABLE_REDIS=1
ENABLE_SYSTEM=1
ENABLE_ATOP=1
ENABLE_SAR=1
ENABLE_CRON=1
ENABLE_ERROR_ANALYSIS=1

# Общие настройки
AUDIT_DIR=/root/audit
PARALLEL_EXECUTION=0
CLEANUP_AFTER_ARCHIVE=1
KEEP_LAST_N_ARCHIVES=5

# Настройки производительности
SAR_FULL_DAY=1             # 1=весь день, 0=рабочее окно
SAR_START_TIME="08:00:00"   # начало рабочего окна
SAR_END_TIME="19:00:00"     # конец рабочего окна
SAR_DAYS=7                  # количество дней

ATOP_FULL_DAY=1            # 1=весь день, 0=рабочее окно
ATOP_START_TIME="09:00"    # начало рабочего окна
ATOP_END_TIME="19:00"      # конец рабочего окна

ERROR_ANALYSIS_DAYS=7      # количество дней для анализа ошибок
```

## Интерпретация результатов

### Структура выходных данных

```
/root/audit/
├── audit_run.log              # Лог выполнения
├── SUMMARY_ALL.md             # Сводный отчет
├── full_audit_YYYYMMDD_HHMMSS.tgz  # Архив всех данных
├── nginx_audit/               # Данные nginx аудита
├── apache_audit/              # Данные apache аудита
├── mysql_audit/               # Данные mysql аудита
├── php_audit/                 # Данные php аудита
├── redis_audit/               # Данные redis аудита
├── bitrix_audit/              # Данные аудита Битрикс (кеш, настройки)
├── system_audit/              # Данные системного аудита
├── atop_audit/                # Данные atop аудита
├── sar_audit/                 # Данные sar аудита
├── cron_audit/                # Данные cron аудита
└── error_analysis/            # Данные анализа ошибок
```

### Ключевые метрики

- **CPU**: загрузка, iowait, steal, idle
- **Memory**: использование, swap, давление памяти
- **Disk**: I/O, использование, очередь
- **Network**: трафик, ошибки, соединения
- **Services**: статус, конфигурация, производительность
- **Bitrix**: размер кеша, количество файлов, настройки безопасности

## Автоматизация через cron

### Ежедневный аудит

```bash
# Добавьте в crontab
0 2 * * * /root/Audit-Bitrix24/run_all_audits.sh --all
```

### Еженедельный полный аудит

```bash
# Добавьте в crontab
0 1 * * 0 /root/Audit-Bitrix24/run_all_audits.sh --all --parallel
```

### Ежедневный анализ производительности

```bash
# Добавьте в crontab
0 3 * * * /root/Audit-Bitrix24/run_all_audits.sh --atop --sar
```

## FAQ

### Q: Почему скрипты не работают?

A: Проверьте требования:
```bash
./check_requirements.sh --verbose
```

### Q: Почему даты отображаются неправильно?

A: Проверьте локали:
```bash
locale -a | grep -E "(en_US|ru_RU)"
```

### Q: Как изменить временное окно для анализа?

A: Используйте переменные окружения:
```bash
SAR_FULL_DAY=0 SAR_START_TIME="09:00:00" SAR_END_TIME="18:00:00" ./collect_sar.sh
```

### Q: Как запустить только определенные модули?

A: Используйте опции оркестратора:
```bash
./run_all_audits.sh --nginx --mysql --php
```

### Q: Как включить параллельное выполнение?

A: Используйте опцию --parallel:
```bash
./run_all_audits.sh --parallel
```

## Troubleshooting

### Проблемы с локалями

1. **Ошибка парсинга дат**: Убедитесь, что установлены `en_US.UTF-8` и `ru_RU.UTF-8`
2. **Неправильное отображение дат**: Проверьте настройки `LC_TIME`
3. **Ошибки в awk**: Убедитесь, что `LC_NUMERIC=C`

### Проблемы с правами доступа

1. **Permission denied**: Запускайте скрипты от root или с sudo
2. **Недоступные файлы**: Проверьте права доступа к логам и конфигурациям

### Проблемы с зависимостями

1. **Команда не найдена**: Установите недостающие пакеты
2. **Версия bash**: Требуется bash >= 4.0

## Лицензия

MIT License

## Поддержка

Для вопросов и предложений создавайте issues в репозитории проекта.
