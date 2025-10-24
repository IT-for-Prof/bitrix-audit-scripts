# Локали и парсинг дат в Bitrix24 Audit Scripts

## Обзор

Этот документ объясняет, как работают локали в скриптах аудита Bitrix24 и почему они критически важны для корректного парсинга дат.

## Почему локали важны?

### Проблема с парсингом дат

Различные утилиты и команды в Linux могут выводить даты в разных форматах в зависимости от настроек локали:

```bash
# С английской локалью
LANG=en_US.UTF-8 date
# Output: Mon Jan 15 14:30:00 UTC 2024

# С русской локалью
LANG=ru_RU.UTF-8 date
# Output: Пн 15 янв 14:30:00 UTC 2024
```

### Источники дат в скриптах

1. **atopsar** - временные метки из бинарных логов atop
2. **sadf/sar** - CSV вывод sysstat с датами
3. **analyze_errors.sh** - даты из логов nginx/apache (monthnum в awk)
4. **date** - генерация временных меток

## Стратегия работы с локалями

### Принципы

1. **LANGUAGE=en_US.UTF-8** - английские сообщения для предсказуемого парсинга
2. **LC_TIME=ru_RU.UTF-8** - русские даты в логах (если доступно)
3. **LC_NUMERIC=C** - точка для чисел (обязательно для awk)

### Автоматическое определение локали в стерильном окружении

Все скрипты используют стерильное окружение (`env -i`) для защиты от интерактивных скриптов (например, `menus.sh`). В этом окружении автоматически определяется лучшая доступная локаль с fallback'ами:

**Приоритет локалей:**
1. `en_US.UTF-8` - основная рекомендуемая локаль
2. `ru_RU.UTF-8` - fallback для систем с русской локалью  
3. `C.UTF-8` или `C.utf8` - минимальная UTF-8 локаль
4. `POSIX` - алиас для C
5. `C` - минимальный ASCII fallback

**Функция определения локали:**
```bash
_detect_locale() {
  if locale -a 2>/dev/null | grep -qi '^en_US\.UTF-8$'; then
    echo "en_US.UTF-8"
  elif locale -a 2>/dev/null | grep -qi '^en_US\.utf8$'; then
    echo "en_US.utf8"
  elif locale -a 2>/dev/null | grep -qi '^ru_RU\.UTF-8$'; then
    echo "ru_RU.UTF-8"
  elif locale -a 2>/dev/null | grep -qi '^ru_RU\.utf8$'; then
    echo "ru_RU.utf8"
  elif locale -a 2>/dev/null | grep -qi '^C\.UTF-8$'; then
    echo "C.UTF-8"
  elif locale -a 2>/dev/null | grep -qi '^C\.utf8$'; then
    echo "C.utf8"
  elif locale -a 2>/dev/null | grep -qi '^POSIX$'; then
    echo "POSIX"
  else
    echo "C"
  fi
}
```

**Использование в стерильном окружении:**
```bash
_LOCALE="$(_detect_locale)"
exec env -i HOME=/root PATH=/usr/sbin:/usr/bin:/bin TERM=xterm-256color \
  LANG="$_LOCALE" LANGUAGE="$_LOCALE" \
  BASH_ENV= _STERILE=1 \
  bash --noprofile --norc "$0" "$@"
```

### Реализация в audit_common.sh

```bash
# Предпочитаемые локали
LANG_PREFS=("en_US.UTF-8" "en_US:en")
LC_TIME_RU='ru_RU.UTF-8'

# Функция проверки доступности локали
locale_has() {
  local want_lc
  want_lc=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  if locale -a >/dev/null 2>&1; then
    locale -a 2>/dev/null | tr '[:upper:]' '[:lower:]' | grep -x -- "${want_lc}" >/dev/null 2>&1
    return $?
  fi
  return 1
}

# Функция настройки локалей
setup_locale() {
  # Определение LANGUAGE
  SCRIPT_LANGUAGE=""
  for lg in "${LANG_PREFS[@]}"; do
    if locale_has "$lg"; then SCRIPT_LANGUAGE="$lg"; break; fi
  done
  if [ -z "$SCRIPT_LANGUAGE" ]; then SCRIPT_LANGUAGE="en_US:en"; fi
  
  # Определение LC_TIME
  SCRIPT_LC_TIME=""
  if locale_has "$LC_TIME_RU"; then
    SCRIPT_LC_TIME="$LC_TIME_RU"
  else
    if locale_has "en_US.UTF-8"; then SCRIPT_LC_TIME="en_US.UTF-8"
    elif locale_has "en_US:en"; then SCRIPT_LC_TIME="en_US:en"
    else SCRIPT_LC_TIME=C
    fi
  fi
}

# Функция запуска команды с правильными локалями
with_locale() {
  LANGUAGE="$SCRIPT_LANGUAGE" LC_TIME="$SCRIPT_LC_TIME" "$@"
}
```

## Использование в скриптах

### Пример с atopsar

```bash
# Без локалей (может работать неправильно)
atopsar -r /var/log/atop/atop_20240115

# С правильными локалями
with_locale atopsar -r /var/log/atop/atop_20240115
```

### Пример с sadf

```bash
# Без локалей (может работать неправильно)
sadf -d -H -s 08:00:00 -e 19:00:00 /var/log/sa/sa15

# С правильными локалями
with_locale sadf -d -H -s 08:00:00 -e 19:00:00 /var/log/sa/sa15
```

### Пример с date

```bash
# Без локалей (может работать неправильно)
date -d "2024-01-15 14:30:00" +%Y-%m-%d

# С правильными локалями
with_locale date -d "2024-01-15 14:30:00" +%Y-%m-%d
```

## Проблемы и решения

### Проблема 1: Неправильный парсинг дат

**Симптомы:**
- Ошибки парсинга дат в awk
- Неправильное отображение временных меток
- Сбои в анализе логов

**Решение:**
```bash
# Проверьте доступные локали
locale -a

# Установите недостающие локали
sudo locale-gen en_US.UTF-8 ru_RU.UTF-8

# Проверьте настройки
locale
```

### Проблема 2: Ошибки в awk

**Симптомы:**
- Ошибки типа "invalid number"
- Неправильная обработка чисел с запятыми

**Решение:**
```bash
# Убедитесь, что LC_NUMERIC=C
export LC_NUMERIC=C

# Или используйте with_locale
with_locale awk '{print $1 + $2}'
```

### Проблема 3: Неправильное отображение дат

**Симптомы:**
- Даты отображаются на английском вместо русского
- Неправильный формат дат

**Решение:**
```bash
# Проверьте настройки LC_TIME
echo $LC_TIME

# Установите правильную локаль времени
export LC_TIME=ru_RU.UTF-8
```

## Тестирование локалей

### Тест 1: Проверка доступности локалей

```bash
# Проверка en_US.UTF-8
if locale_has "en_US.UTF-8"; then
    echo "✅ en_US.UTF-8 доступна"
else
    echo "❌ en_US.UTF-8 недоступна"
fi

# Проверка ru_RU.UTF-8
if locale_has "ru_RU.UTF-8"; then
    echo "✅ ru_RU.UTF-8 доступна"
else
    echo "❌ ru_RU.UTF-8 недоступна"
fi
```

### Тест 2: Проверка парсинга дат

```bash
# Тест парсинга дат
test_date="2024-01-15 14:30:00"
if with_locale date -d "$test_date" +%Y-%m-%d >/dev/null 2>&1; then
    echo "✅ Парсинг дат работает"
else
    echo "❌ Парсинг дат не работает"
fi
```

### Тест 3: Проверка работы с числами

```bash
# Тест работы с числами
if with_locale awk 'BEGIN{print 1.5 + 2.3}' | grep -q "3.8"; then
    echo "✅ Работа с числами работает"
else
    echo "❌ Работа с числами не работает"
fi
```

## Отладка проблем с локалями

### Шаг 1: Проверка текущих настроек

```bash
# Проверка всех настроек локали
locale

# Проверка доступных локалей
locale -a

# Проверка переменных окружения
env | grep -E "(LANG|LC_)"
```

### Шаг 2: Тестирование команд

```bash
# Тест команды date
date
LANGUAGE=en_US.UTF-8 LC_TIME=ru_RU.UTF-8 date

# Тест команды awk
echo "1.5" | awk '{print $1 + 1}'
LC_NUMERIC=C echo "1.5" | awk '{print $1 + 1}'
```

### Шаг 3: Проверка логов

```bash
# Проверка логов на предмет ошибок локали
grep -i "locale\|encoding\|utf" /var/log/syslog
grep -i "locale\|encoding\|utf" /var/log/messages
```

## Рекомендации

### Для разработчиков

1. **Всегда используйте with_locale** для команд, которые работают с датами
2. **Проверяйте доступность локалей** перед их использованием
3. **Тестируйте парсинг дат** в различных локалях
4. **Документируйте зависимости** от локалей

### Для администраторов

1. **Устанавливайте необходимые локали** на всех серверах
2. **Проверяйте настройки локали** перед запуском скриптов
3. **Мониторьте ошибки** связанные с локалями
4. **Обновляйте локали** при обновлении системы

### Для пользователей

1. **Запускайте check_requirements.sh** перед использованием скриптов
2. **Обращайте внимание на предупреждения** о локалях
3. **Сообщайте о проблемах** с парсингом дат
4. **Следуйте инструкциям** по установке локалей

## Заключение

Правильная настройка локалей критически важна для корректной работы скриптов аудита Bitrix24. Следуйте рекомендациям в этом документе для обеспечения стабильной работы всех компонентов системы.

При возникновении проблем используйте инструменты диагностики и следуйте пошаговым инструкциям по устранению неполадок.
