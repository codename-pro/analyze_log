# analyze_log.sh

Bash-скрипт для анализа `access.log` nginx. Формирует сводный отчёт: домены, IP,
User-Agent, HTTP-методы, запросы и суммарное время обработки.

Можно передать один файл или несколько — все данные суммируются в **единый отчёт**.
Скрипт не требует зависимостей, не ходит в сеть и не использует GeoIP.

---

## Возможности

- Один или несколько файлов за запуск, включая glob (`access.log*`).
- Без аргументов берёт все `access.log*` из текущей папки.
- Единый отчёт по всем файлам: счётчики и проценты суммируются.
- Разделы: обработанные строки, домены, IP, User-Agent, методы, запросы, CPers.
- Проценты считаются от общего числа обработанных строк.
- Query-строка в запросах сохраняется.
- Понимает логи как с `$host` в первом поле, так и без него.
- Настраиваемый размер топов (`-n`) и сохранение отчёта в файл (`-o`).
- Временные файлы создаются в `TMPDIR` и удаляются автоматически.
- Дубликаты файлов игнорируются.

---

## Требования

- Linux, `bash` 4+.
- `awk`, `sort`, `head`, `wc`, `mktemp`, `readlink`, `cp`.

---

## Установка

```bash
git clone https://github.com/<username>/<repo>.git
cd <repo>
install -m 755 analyze_log.sh ~/.local/bin/analyze_log
```

Если `~/.local/bin` отсутствует в `PATH`:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

Проверка:

```bash
analyze_log --help
```

Скрипт самодостаточен — можно просто скопировать его на сервер:

```bash
scp analyze_log.sh user@server:/var/log/nginx/
ssh user@server 'chmod +x /var/log/nginx/analyze_log.sh'
```

> Если файл передавался через Windows, проверьте переводы строк:
> `dos2unix analyze_log.sh`.

### Обновление

```bash
ln -sf ~/tools/log-analyzer/analyze_log.sh ~/.local/bin/analyze_log
git -C ~/tools/log-analyzer pull
```

---

## Использование

```bash
# один файл
./analyze_log.sh access.log

# несколько файлов — единый отчёт
./analyze_log.sh access.log.1 access.log.2 access.log.3

# все подходящие файлы
./analyze_log.sh access.log*

# без аргументов — все access.log* из текущей папки
./analyze_log.sh

# топ-30 и сохранение в файл
./analyze_log.sh access.log* -n 30 -o report.txt

# файлы из разных папок
./analyze_log.sh /var/log/nginx/access.log* /backup/logs/access.log.1
```

### Опции

| Опция | Описание |
|-------|----------|
| `-n N` | Сколько строк показывать в каждом топе. По умолчанию `20`. |
| `-o FILE` | Дополнительно сохранить отчёт в файл. Отчёт также выводится в stdout. |
| `-h`, `--help` | Показать справку. |

---

## Формат лога

Ожидается стандартный nginx access-log, где первое поле — `$host`, второе —
`$remote_addr`. Пример `log_format`:

```nginx
log_format main '$host $remote_addr - $remote_user [$time_local] "$request" '
                '$status $body_bytes_sent "$http_referer" "$http_user_agent" '
                '$request_time $upstream_response_time';

access_log /var/log/nginx/access.log main;
```

Строка такого лога:

```
example.com 203.0.113.10 - - [22/Oct/2026:00:00:46 +0300] "GET /catalog/ HTTP/1.1" 200 79249 "-" "Mozilla/5.0 (compatible; ExampleBot/1.0)" 417006 103949:60936
```

- Домен берётся из первого поля, IP — из второго.
- Если первое поле само является IP, скрипт определяет это автоматически:
  домен будет `-`, а хост по возможности берётся из URL.
- Время запроса — первое число после User-Agent (в примере `417006` мкс).
  Если этого поля нет, раздел CPers будет помечен как `n/a`.

Скрипт ориентируется на кавычки, а не на фиксированные номера полей, поэтому
поддерживаются и другие похожие форматы.

---

## Пример отчёта

```
Working...
Processed 20000 strings

Top 2 of 2 domains:
-------------------------------------------
 15000  75.00%  example.com
  5000  25.00%  www.example.com

Top 20 of 1200 IPs:
-------------------------------------------
  4200  21.00%  192.0.2.10
  2600  13.00%  198.51.100.25
  1800   9.00%  203.0.113.7

Top 20 of 85 User-Agents:
-------------------------------------------
  5500  27.50%  Mozilla/5.0 (compatible; ExampleBot/1.0; +http://example.com/bot)
  3200  16.00%  Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 ...

Top 3 of 3 METHODs:
-------------------------------------------
 16000  80.00%  GET
  3800  19.00%  POST
   200   1.00%  HEAD

Top 20 of 4200 Requests:
-------------------------------------------
  3200  16.00%  POST    example.com/api/search
  2400  12.00%  GET     example.com/catalog/

Top CPers: (842.315 total)
-------------------------------------------
 41.208  example.com/api/search
 27.914  example.com/catalog/
 18.552  example.com/product/123
```

User-Agent и query-строки в примере сокращены.

---

## Как считаются метрики

- `Processed N strings` — общее число строк во всех переданных файлах.
- Проценты — `количество / Processed × 100`.
- `Top X of Y` — `X` показано, `Y` уникальных значений всего.
- `Requests` — уникальные пары «метод + домен + путь с query-строкой».
- `CPers` — суммарное время обработки по URL в секундах: сумма поля времени (мкс)
  / 1 000 000. Если времени в логе нет, раздел будет `n/a`.

---

## Ограничения

- Сжатые логи (`.gz`) не читаются. Распакуйте заранее:
  ```bash
  zcat access.log.1.gz > /tmp/access.log.1
  ./analyze_log.sh /tmp/access.log.1
  ```
- Нет геолокации IP.
- Неэкранированные кавычки в User-Agent или referer могут сломать разбор строки
  (nginx по умолчанию экранирует их как `\x22`).

---

## Возможные проблемы

**«не указаны файлы логов и в текущей папке нет access.log\*»**
Запустите скрипт из папки с логами или передайте пути явно.

**«файл не существует или недоступен для чтения»**
Проверьте права: `ls -l`, при необходимости `sudo`.

**Пустые или странные домены**
Проверьте, что в `log_format` первым полем действительно идёт `$host`.
