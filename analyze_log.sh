#!/usr/bin/env bash
#
# Отчёт по access-логам nginx (формат с vhost в первом поле).
# Поддерживает один или несколько файлов — данные суммируются в один отчёт.
#
# Примеры:
#   ./analyze_log.sh access.log
#   ./analyze_log.sh access.log.19 access.log.20 access.log.21
#   ./analyze_log.sh access.log* -n 30
#   ./analyze_log.sh access.log -o report.txt
#
set -uo pipefail

TOP=20
OUT=""
FILES=()

usage() {
    cat <<'EOF'
Использование: analyze_log.sh [опции] <файл_лога> [файл_лога ...]

Опции:
  -n N        сколько строк показывать в каждом топе (по умолчанию 20)
  -o FILE     дополнительно сохранить отчёт в файл
  -h, --help  показать эту справку

Без аргументов скрипт обрабатывает все файлы access.log* в текущей папке.
Все указанные файлы обрабатываются за один проход и попадают в единый отчёт.
Проценты считаются от общего числа обработанных строк.
CPers — суммарное время обработки запросов по URL (сек), берётся из поля
времени запроса в логе (предпоследнее поле, микросекунды).
EOF
}

die() {
    echo "Ошибка: $*" >&2
    exit 1
}

while (($#)); do
    case "$1" in
        -n)
            [[ $# -ge 2 ]] || die "после -n нужно указать число"
            TOP="$2"
            shift 2
            ;;
        -n*)
            TOP="${1#-n}"
            shift
            ;;
        -o)
            [[ $# -ge 2 ]] || die "после -o нужно указать имя файла"
            OUT="$2"
            shift 2
            ;;
        -o*)
            OUT="${1#-o}"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            while (($#)); do
                FILES+=("$1")
                shift
            done
            ;;
        -*)
            die "неизвестная опция: $1 (см. --help)"
            ;;
        *)
            FILES+=("$1")
            shift
            ;;
    esac
done

[[ "$TOP" =~ ^[0-9]+$ ]] && ((TOP > 0)) || die "-n должно быть положительным целым числом"

if ((${#FILES[@]} == 0)); then
    shopt -s nullglob
    FILES=(access.log*)
    shopt -u nullglob
    ((${#FILES[@]} > 0)) || die "не указаны файлы логов и в текущей папке нет access.log*"
fi

# Убираем дубликаты и проверяем файлы
declare -A seen=()
INPUTS=()
for f in "${FILES[@]}"; do
    [[ -f "$f" && -r "$f" ]] || die "файл не существует или недоступен для чтения: $f"
    key=$(readlink -f -- "$f" 2>/dev/null || echo "$f")
    [[ -n "${seen[$key]:-}" ]] && continue
    seen[$key]=1
    INPUTS+=("$f")
done

TMP=$(mktemp -d "${TMPDIR:-/tmp}/analyze_log.XXXXXX") || die "не удалось создать временную папку"
trap 'rm -rf -- "$TMP"' EXIT

# Один проход по всем файлам: агрегаты во временные файлы.
awk -v domf="$TMP/domains" \
    -v ipf="$TMP/ips" \
    -v uaf="$TMP/uas" \
    -v methf="$TMP/methods" \
    -v reqf="$TMP/requests" \
    -v cpf="$TMP/cpers" '
BEGIN { FS = "\"" }

{
    # Поле 1: "vhost ip - - [date]", поле 2: "METHOD URL PROTO"
    n = split($1, a, " ")
    if (n < 2) next

    f1 = a[1]
    f2 = a[2]

    # Формат без vhost: первое поле — сам IP
    if (f1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ || f1 ~ /^[0-9A-Fa-f:]*:[0-9A-Fa-f:]*$/) {
        host = "-"
        ip = f1
    } else {
        host = f1
        ip = f2
    }

    if (NF < 6) next

    split($2, r, " ")
    method = r[1]
    url = r[2]
    if (method == "" || url == "") next

    ua = $6

    # Абсолютный URL -> путь; при отсутствии vhost берём хост из URL
    if (url ~ /^https?:\/\//) {
        sub(/^https?:\/\//, "", url)
        p = index(url, "/")
        if (p > 0) {
            if (host == "-") host = substr(url, 1, p - 1)
            url = substr(url, p)
        } else {
            if (host == "-") host = url
            url = "/"
        }
    }

    # Время запроса: первое число после последнего кавычечного поля
    t = 0
    if (NF > 6) {
        tail = $NF
        if (tail ~ /^[[:space:]]*[0-9]+([[:space:]]|$)/) {
            split(tail, ta, " ")
            t = ta[1] + 0
        }
    }

    dom[host]++
    ips[ip]++
    uas[ua]++
    meth[method]++

    reqs[method "\t" host url]++

    cpkey = host url
    cpers[cpkey] += t
    total_time += t
}

END {
    for (k in dom)   print dom[k]   "\t" k > domf
    for (k in ips)   print ips[k]   "\t" k > ipf
    for (k in uas)   print uas[k]   "\t" k > uaf
    for (k in meth)  print meth[k]  "\t" k > methf
    for (k in reqs)  print reqs[k]  "\t" k > reqf
    for (k in cpers) printf "%.0f\t%s\n", cpers[k], k > cpf

    print NR > (domf ".total")
    printf "%.0f\n", total_time > (cpf ".total")
}
' "${INPUTS[@]}"

LINES=$(cat "$TMP/domains.total" 2>/dev/null || echo 0)
TOTAL_TIME=$(cat "$TMP/cpers.total" 2>/dev/null || echo 0)
[[ -n "$LINES" ]] || LINES=0
[[ -n "$TOTAL_TIME" ]] || TOTAL_TIME=0

SEP='-------------------------------------------'
REPORT="$TMP/report"

sort_desc() {
    # $1 — исходный файл, $2 — отфильтрованный топ
    sort -t $'\t' -k1,1nr -k2,2 -- "$1" > "$1.sorted"
    head -n "$TOP" "$1.sorted" > "$2"
}

# Некоторые файлы могли не создаться (нет данных)
for f in domains ips uas methods requests cpers; do
    [[ -f "$TMP/$f" ]] || : > "$TMP/$f"
done

sort_desc "$TMP/domains"  "$TMP/domains.top"
sort_desc "$TMP/ips"      "$TMP/ips.top"
sort_desc "$TMP/uas"      "$TMP/uas.top"
sort_desc "$TMP/methods"  "$TMP/methods.top"
sort_desc "$TMP/requests" "$TMP/requests.top"
sort_desc "$TMP/cpers"    "$TMP/cpers.top"

count_lines() { wc -l < "$1" | tr -d ' '; }

{
    echo "Working..."
    echo "Processed $LINES strings"
    echo

    echo "Top $(count_lines "$TMP/domains.top") of $(count_lines "$TMP/domains") domains:"
    echo "$SEP"
    awk -F'\t' -v total="$LINES" '{
        pct = (total > 0) ? $1 / total * 100 : 0
        printf "%6d  %5.2f%%  %s\n", $1, pct, $2
    }' "$TMP/domains.top"
    echo

    echo "Top $(count_lines "$TMP/ips.top") of $(count_lines "$TMP/ips") IPs:"
    echo "$SEP"
    awk -F'\t' -v total="$LINES" '{
        pct = (total > 0) ? $1 / total * 100 : 0
        printf "%6d  %5.2f%%  %s\n", $1, pct, $2
    }' "$TMP/ips.top"
    echo

    echo "Top $(count_lines "$TMP/uas.top") of $(count_lines "$TMP/uas") User-Agents:"
    echo "$SEP"
    awk -F'\t' -v total="$LINES" '{
        pct = (total > 0) ? $1 / total * 100 : 0
        printf "%6d  %5.2f%%  %s\n", $1, pct, $2
    }' "$TMP/uas.top"
    echo

    echo "Top $(count_lines "$TMP/methods.top") of $(count_lines "$TMP/methods") METHODs:"
    echo "$SEP"
    awk -F'\t' -v total="$LINES" '{
        pct = (total > 0) ? $1 / total * 100 : 0
        printf "%6d  %5.2f%%  %s\n", $1, pct, $2
    }' "$TMP/methods.top"
    echo

    echo "Top $(count_lines "$TMP/requests.top") of $(count_lines "$TMP/requests") Requests:"
    echo "$SEP"
    awk -F'\t' -v total="$LINES" '{
        pct = (total > 0) ? $1 / total * 100 : 0
        printf "%6d  %5.2f%%  %-7s %s\n", $1, pct, $2, $3
    }' "$TMP/requests.top"
    echo

    if (( TOTAL_TIME > 0 )); then
        echo "Top CPers: ($(awk -v t="$TOTAL_TIME" 'BEGIN { printf "%.3f", t / 1000000 }') total)"
        echo "$SEP"
        awk -F'\t' '{ printf "%6.3f  %s\n", $1 / 1000000, $2 }' "$TMP/cpers.top"
    else
        echo "Top CPers: (n/a)"
    fi
} > "$REPORT"

cat "$REPORT"

if [[ -n "$OUT" ]]; then
    if ! cp -- "$REPORT" "$OUT" 2>/dev/null; then
        die "не удалось записать отчёт в файл: $OUT"
    fi
    echo "Отчёт сохранён: $OUT" >&2
fi
