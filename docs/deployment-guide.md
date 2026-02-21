# Руководство по развёртыванию: Linux SBC как NAT-роутер с zapret2 DPI bypass

Этот документ — полная инструкция для настройки Linux одноплатника (SBC) в качестве NAT-роутера
с DPI bypass через zapret2 (nfqws2 + Lua). Проверено на Orange Pi 3B (Ubuntu 22.04),
адаптируется на любой Linux с двумя ethernet-интерфейсами.

Документ можно передать Claude для автоматической настройки на новом устройстве.

---

## Оглавление

1. [Топология и требования](#1-топология-и-требования)
2. [Bridge vs NAT: когда что выбирать](#2-bridge-vs-nat-когда-что-выбирать)
3. [Подготовка: установка zapret2](#3-подготовка-установка-zapret2)
4. [Настройка сети (nat-setup.sh)](#4-настройка-сети-nat-setupsh)
5. [Структура проекта и файлы](#5-структура-проекта-и-файлы)
6. [Система стратегий](#6-система-стратегий)
7. [Создание и адаптация стратегий](#7-создание-и-адаптация-стратегий)
8. [Перевод Flowseal .bat → zapret2](#8-перевод-flowseal-bat--zapret2)
9. [systemd-сервис](#9-systemd-сервис)
10. [Критические грабли](#10-критические-грабли)
11. [Диагностика](#11-диагностика)
12. [Чеклист после развёртывания](#12-чеклист-после-развёртывания)

---

## 1. Топология и требования

### Целевая схема

```
Провайдер → Конвертер → [WAN_IFACE] Orange Pi (NAT, 10.10.10.1/24) [LAN_IFACE] → Роутер (DHCP, DMZ) → Клиенты
                                                                                         ↑
                                                                        wlan0 (WiFi от роутера) — SSH управление
```

Orange Pi выполняет:
- NAT masquerade (все исходящие пакеты получают IP провайдера)
- DMZ DNAT (все входящие соединения перенаправляются на роутер)
- DPI bypass через nfqws2 (POSTNAT-схема — перехват после NAT)
- DHCP-сервер на LAN-интерфейсе

### Требования к железу

- Linux SBC (Orange Pi, Raspberry Pi, Banana Pi, etc.)
- 2 ethernet-интерфейса (встроенный + USB-адаптер, например RTL8153)
- WiFi (опционально, для SSH-управления в обход основных интерфейсов)
- Ubuntu/Debian (тестировалось на Ubuntu 22.04 Jammy)
- NetworkManager для управления сетью

### Что нужно знать заранее

| Параметр | Пример | Как узнать |
|----------|--------|------------|
| WAN-интерфейс | `enx00e04c176c60` | `ip link show` — USB-адаптер, имя по MAC |
| LAN-интерфейс | `eth0` | `ip link show` — встроенный ethernet |
| IP роутера | `10.10.10.190` | После настройки: `cat /var/lib/misc/dnsmasq.leases` |
| MAC роутера | `50:ff:20:7a:5d:ac` | С роутера: `ip link show` на WAN-порту |

---

## 2. Bridge vs NAT: когда что выбирать

### Bridge (прозрачный мост, L2)

**Топология**: `Провайдер → [WAN] ── br0 ── [LAN] → Роутер → Клиенты`

| Плюсы | Минусы |
|-------|--------|
| Невидим для сети | **fake, fakedsplit, seqovl НЕ РАБОТАЮТ** |
| Нулевая конфигурация клиентов | wssize не работает |
| Простой откат — вынул, воткнул напрямую | Только multisplit/multidisorder |
| | Нужен br_netfilter + sysctl |
| | SBC упал = сеть лежит |

**Почему fake не работает на мосту**: мост перехватывает пакеты в FORWARD chain, но отправляет
fake-пакеты через raw socket из OUTPUT chain. Разница в тайминге между raw socket и NF_ACCEPT
оригинального пакета приводит к тому, что DPI видит их в неправильном порядке или игнорирует.

### NAT-роутер (L3) — РЕКОМЕНДУЕТСЯ

**Топология**: `Провайдер → [WAN] Orange Pi (NAT) [LAN] → Роутер (DMZ) → Клиенты`

| Плюсы | Минусы |
|-------|--------|
| **ВСЕ техники работают** | Двойной NAT (решается DMZ) |
| seqovl — самая эффективная | Нужен DHCP-сервер |
| POSTNAT-схема из документации zapret2 | Нужно перенастроить роутер |
| Входящий трафик через prerouting (wssize) | Сложнее начальная настройка |

### Таблица совместимости техник

| Техника | Bridge | NAT |
|---------|--------|-----|
| multisplit / multidisorder | Да | Да |
| fake (инъекция фейковых пакетов) | **Нет** | Да |
| fakedsplit / fakeddisorder | **Нет** | Да |
| seqovl (sequence overlap) | **Нет** | Да |
| wssize (размер TCP окна) | **Нет** | Да |
| syndata | **Нет** | Да |

**Вывод**: Если DPI вашего провайдера не обходится простым разделением пакетов
(multisplit) — нужен NAT. Большинство российских ISP в 2025+ требуют fake + seqovl.

---

## 3. Подготовка: установка zapret2

```bash
# Клонировать zapret2
cd /opt
git clone https://github.com/bol-van/zapret2.git
cd zapret2

# Установить бинарники для вашей архитектуры
./install_bin.sh

# Проверить что nfqws2 работает
/opt/zapret2/nfq2/nfqws2 --help
```

Нужны также Flowseal-списки и blob-файлы. Структура:

```
/opt/zapret-scripts/
├── zapret-latest/
│   ├── lists/
│   │   ├── list-general.txt      # Домены для обхода
│   │   ├── list-google.txt       # Google-домены
│   │   ├── list-exclude.txt      # Исключения
│   │   ├── ipset-all.txt         # IP-адреса для обхода
│   │   └── ipset-exclude.txt     # Исключённые IP
│   └── bin/
│       ├── tls_clienthello_max_ru.bin
│       ├── tls_clienthello_www_google_com.bin  # (может также быть в /opt/zapret2/files/fake/)
│       └── quic_initial_www_google_com.bin     # (может также быть в /opt/zapret2/files/fake/)
```

---

## 4. Настройка сети (nat-setup.sh)

**Запускается один раз вручную.** После этого настройки сохраняются через nmcli autoconnect.

```bash
#!/usr/bin/env bash
set -e

# === АДАПТИРУЙ ЭТИ ПЕРЕМЕННЫЕ ПОД СВОЁ УСТРОЙСТВО ===
WAN_IFACE="enx00e04c176c60"    # USB-адаптер к провайдеру
LAN_IFACE="eth0"               # Встроенный ethernet к роутеру
LAN_SUBNET="10.10.10"          # Подсеть LAN (без последнего октета)
ROUTER_MAC="50:ff:20:7a:5d:ac" # MAC WAN-порта роутера (для статического DHCP)
ROUTER_IP="${LAN_SUBNET}.190"  # Статический IP роутера
# =====================================================

# 1. Удалить bridge (если был)
nmcli con delete br0 br0-eth0 br0-usb 2>/dev/null || true
nmcli con delete "Wired connection 1" "Wired connection 2" 2>/dev/null || true

# 2. WAN — DHCP от провайдера
nmcli con delete wan 2>/dev/null || true
nmcli con add type ethernet ifname "$WAN_IFACE" con-name wan \
    ipv4.method auto connection.autoconnect yes

# 3. LAN — статический IP, DHCP-сервер
nmcli con delete lan 2>/dev/null || true
nmcli con add type ethernet ifname "$LAN_IFACE" con-name lan \
    ipv4.method manual ipv4.addresses "${LAN_SUBNET}.1/24" \
    ipv6.method disabled connection.autoconnect yes

# 4. IP forwarding (переживает перезагрузку)
echo "net.ipv4.ip_forward=1" | sudo tee /etc/sysctl.d/99-nat.conf
sudo sysctl -w net.ipv4.ip_forward=1

# 5. DHCP-сервер (dnsmasq)
sudo apt-get update && sudo apt-get install -y dnsmasq
sudo mkdir -p /etc/dnsmasq.d
cat << EOF | sudo tee /etc/dnsmasq.d/lan.conf
# NAT router - DHCP on LAN
interface=${LAN_IFACE}
bind-dynamic
dhcp-range=${LAN_SUBNET}.100,${LAN_SUBNET}.200,24h
dhcp-option=option:router,${LAN_SUBNET}.1
dhcp-option=option:dns-server,8.8.8.8,1.1.1.1
dhcp-host=${ROUTER_MAC},${ROUTER_IP},router
EOF
sudo systemctl enable --now dnsmasq

# 6. Убрать bridge-артефакты (если были)
sudo rm -f /etc/modules-load.d/br_netfilter.conf
sudo rm -f /etc/sysctl.d/99-bridge.conf

# 7. Активировать интерфейсы
nmcli con up wan || echo "WARNING: WAN not connected yet"
nmcli con up lan || echo "WARNING: LAN not connected yet"

echo "Done. Reboot recommended."
```

### ВАЖНО: `bind-dynamic` вместо `bind-interfaces`

dnsmasq с `bind-interfaces` падает при загрузке если eth0 ещё не поднят NetworkManager'ом.
**Всегда используй `bind-dynamic`** — он ждёт появления интерфейса.

### Порядок физических подключений

1. Запусти `nat-setup.sh` с отключёнными кабелями (кроме WiFi для SSH)
2. Перезагрузи
3. Подключи LAN-кабель (Orange Pi eth0 → WAN-порт роутера)
4. Проверь что роутер получил IP: `cat /var/lib/misc/dnsmasq.leases`
5. Подключи WAN-кабель (конвертер провайдера → USB-адаптер Orange Pi)
6. Проверь: `curl ifconfig.me`

---

## 5. Структура проекта и файлы

```
/opt/zapret-scripts/                  # Рабочая директория
├── main_script.sh                    # Главный скрипт (NAT + nftables + запуск nfqws2)
├── stop_and_clean_nft.sh             # Остановка nfqws2 + очистка nftables
├── conf.env                          # Конфигурация (сеть + имя активной стратегии)
├── nat-setup.sh                      # Одноразовая настройка сети
├── strategies/                       # Стратегии DPI bypass
│   └── flowseal_fake_tls_auto_alt2.sh
└── zapret-latest/                    # Flowseal: списки и blob-файлы
    ├── lists/
    │   ├── list-general.txt
    │   ├── list-google.txt
    │   ├── list-exclude.txt
    │   ├── ipset-all.txt
    │   └── ipset-exclude.txt
    └── bin/
        └── *.bin

/opt/zapret2/                         # zapret2 (установлен отдельно)
├── nfq2/nfqws2                       # Бинарник nfqws2
├── lua/                              # Lua-библиотеки
│   ├── zapret-lib.lua
│   ├── zapret-antidpi.lua
│   └── zapret-auto.lua
└── files/fake/                       # Стандартные blob-файлы
    ├── quic_initial_www_google_com.bin
    ├── tls_clienthello_www_google_com.bin
    ├── zero_256.bin
    └── stun.bin
```

### conf.env

```bash
wan_iface=enx00e04c176c60       # Имя WAN-интерфейса
lan_iface=eth0                  # Имя LAN-интерфейса
keenetic_ip=10.10.10.190        # IP роутера (DMZ-цель)
strategy=flowseal_fake_tls_auto_alt2  # Активная стратегия (имя файла без .sh)
```

### Что переживает перезагрузку

| Компонент | Переживает? | Механизм |
|-----------|-------------|----------|
| IP forwarding | Да | `/etc/sysctl.d/99-nat.conf` |
| WAN/LAN интерфейсы | Да | nmcli autoconnect |
| DHCP-сервер | Да | systemd dnsmasq enabled |
| nftables правила | Пересоздаются | main_script.sh при старте сервиса |
| nfqws2 процесс | Пересоздаётся | main_script.sh при старте сервиса |

---

## 6. Система стратегий

Стратегия — файл `.sh` в директории `strategies/`, который source'ится из `main_script.sh`.

### Формат файла стратегии

```bash
# strategies/my_strategy.sh
# Описание: что делает, для какого провайдера тестировалось, дата теста

# Переопределение портов для nftables (опционально)
# По умолчанию: TCP_PORTS="80,443" UDP_PORTS="443"
TCP_PORTS="80,443,2053,2083,2087,2096,8443"
UDP_PORTS="443,19294-19344,50000-50100"

# Blob-файлы (пути подставляются при source через $NFQWS2_FAKES, $FLOWSEAL_BIN)
# НЕЛЬЗЯ использовать имена: fake_default_tls, fake_default_http, fake_default_quic
BLOB_OPTS="\
--blob=quic_google:@$NFQWS2_FAKES/quic_initial_www_google_com.bin \
--blob=tls_google:@$NFQWS2_FAKES/tls_clienthello_www_google_com.bin \
--blob=zero_256:@$NFQWS2_FAKES/zero_256.bin"

# Профили стратегии (heredoc с 'EOF' — $LISTS_DIR подставится через eval при запуске)
read -r -d '' STRATEGY << 'EOF' || true
--filter-udp=443 --filter-l7=quic --hostlist=$LISTS_DIR/list-general.txt --payload=quic_initial --lua-desync=fake:blob=quic_google:repeats=11
--new
--filter-tcp=443 --filter-l7=tls --hostlist=$LISTS_DIR/list-general.txt --payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:tcp_seq=10000000:repeats=8 --lua-desync=multisplit:pos=1:seqovl=681:seqovl_pattern=tls_google
EOF
```

### Доступные переменные при source

| Переменная | Значение | Подставляется |
|------------|----------|---------------|
| `$NFQWS2_FAKES` | `/opt/zapret2/files/fake` | При source (в BLOB_OPTS) |
| `$FLOWSEAL_BIN` | `/opt/zapret-scripts/zapret-latest/bin` | При source (в BLOB_OPTS) |
| `$LISTS_DIR` | `/opt/zapret-scripts/zapret-latest/lists` | При eval (в STRATEGY) |

### Переключение стратегии

```bash
# Способ 1: изменить conf.env
sed -i 's/strategy=.*/strategy=my_new_strategy/' /opt/zapret-scripts/conf.env
systemctl restart zapret_discord_youtube

# Способ 2: временно через аргумент (не меняет conf.env)
/opt/zapret-scripts/main_script.sh -strategy my_new_strategy
```

---

## 7. Создание и адаптация стратегий

### Методология

1. **Запусти blockcheck2** для своего провайдера:
   ```bash
   cd /opt/zapret2
   BATCH=1 DOMAINS="youtube.com discord.com" ./blockcheck2.sh | tee /tmp/bc.log
   ```

2. **Найди работающие техники** (строки с `OK` в результатах)

3. **Собирай стратегию инкрементально** — один профиль за раз:
   - TCP 443 TLS (YouTube, Discord web) — обычно самый важный
   - UDP 443 QUIC (YouTube видео-стриминг)
   - Discord-специфичные порты (19294-19344, 50000-50100)
   - HTTP 80 (редко нужен)

4. **Тестируй каждый профиль отдельно** перед объединением

### Порядок профилей (ВАЖНО — first match wins)

nfqws2 проверяет профили сверху вниз, первое совпадение побеждает. Располагай от частного к общему:

```
1. Самый специфичный:  --hostlist-domains=discord.media        (один домен)
2. Конкретный список:  --hostlist=list-google.txt               (короткий список)
3. Общий список:       --hostlist=list-general.txt              (большой список)
4. По IP:              --ipset=ipset-all.txt                    (фоллбек для IP без SNI)
```

**Частая ошибка**: общий `--filter-tcp=443` стоит выше специфичного Discord-профиля.
Общий профиль срабатывает первым, Discord до своего профиля не доходит.

### Выбор техники

| Ситуация | Техника | Почему |
|----------|---------|--------|
| Простой DPI (смотрит первый пакет) | `multisplit:pos=1,midsld` | Разделяет SNI между пакетами |
| Умный DPI (собирает пакеты) | `fake` + `multisplit` с `seqovl` | Fake сбивает реассемблер |
| Агрессивный DPI | `fake:tcp_seq=N:tls_mod=rnd,dupsid,sni=X` | Полный фейковый TLS hello |
| Блокировка QUIC | `fake:blob=quic_google:repeats=6-11` | Засыпать фейковыми QUIC |
| Discord голос/видео | `fake:blob=zero_256:repeats=6` на 19294-19344 | Discord-специфичный |
| Поздняя блокировка (зависание на 10КБ) | `wssize:wsize=1:scale=6` | Ограничить TCP окно |

### Выбор fooling

| Fooling | Надёжность | Комментарий |
|---------|-----------|-------------|
| `tcp_seq=10000000` | **Высокая** | Сервер отбрасывает (неправильный seq), DPI принимает. Лучший выбор |
| `tcp_md5` | **Высокая** | Сервер игнорирует (RFC), DPI не проверяет TCP options |
| `badsum` | Средняя | Некоторые NIC делают checksum offload — пакет может пройти с плохой суммой |
| `ip_ttl=N` | Низкая | Надо угадать hop count — слишком мало = дропнется до DPI |

**Рекомендация**: `tcp_seq=10000000` как основной fooling. На мосту fooling бесполезен
(fake не работает).

### Обнаружение конфликтов между профилями

Конфликт происходит когда:
- Один и тот же протокол + порт + хост попадает в несколько профилей
- Первый совпавший профиль побеждает — остальные игнорируются
- UDP-профили без `--filter-l7` ловят весь UDP на этом порту

**Отладка**: запусти nfqws2 без `--daemon`, смотри stdout — какой профиль матчится.

---

## 8. Перевод Flowseal .bat → zapret2

Flowseal использует zapret1 (nfqws) синтаксис. Ключевые отличия при переводе.

### Главные принципы

1. **Comma-separated техники → отдельные `--lua-desync`**:
   ```
   Flowseal:  --dpi-desync=fake,multisplit --dpi-desync-split-seqovl=681
   zapret2:   --lua-desync=fake:blob=...:repeats=8 --lua-desync=multisplit:pos=1:seqovl=681
   ```

2. **Файлы → blob-имена**: Flowseal ссылается на файлы (`"%BIN%file.bin"`).
   zapret2 загружает blob'ы глобально (`--blob=name:@path`), потом ссылается по имени (`blob=name`).

3. **Глобальный fooling → per-function args**: Flowseal `--dpi-desync-fooling=badseq` применяется
   ко всему профилю. В zapret2 fooling-аргументы идут на каждый `--lua-desync` отдельно.

4. **Фильтр портов**: Flowseal `--wf-tcp=`/`--wf-udp=` — не нужны в Linux,
   nftables фильтрует порты. Но `--filter-tcp=`/`--filter-udp=` внутри профиля — нужны.

### Таблица маппинга параметров

| Flowseal (nfqws1) | zapret2 (nfqws2) |
|-------------------|-------------------|
| `--dpi-desync=fake,multisplit` | `--lua-desync=fake:... --lua-desync=multisplit:...` |
| `--dpi-desync-split-seqovl=681` | `seqovl=681` (аргумент multisplit) |
| `--dpi-desync-split-pos=1` | `pos=1` (аргумент multisplit) |
| `--dpi-desync-fooling=badseq` | `tcp_seq=N` (аргумент fake) |
| `--dpi-desync-badseq-increment=10000000` | `tcp_seq=10000000` |
| `--dpi-desync-repeats=8` | `repeats=8` (аргумент fake) |
| `--dpi-desync-split-seqovl-pattern="file.bin"` | `seqovl_pattern=blob_name` (загрузить файл как blob) |
| `--dpi-desync-fake-tls-mod=rnd,dupsid,sni=X` | `tls_mod=rnd,dupsid,sni=X` (аргумент fake) |
| `--dpi-desync-fake-quic="file.bin"` | `--blob=name:@file` + `blob=name` в fake |
| `--dpi-desync-fake-http="file.bin"` | Аналогично: загрузить как blob, ссылаться по имени |
| `--ip-id=zero` | `ip_id=zero` (аргумент lua-desync функции) |
| `--dpi-desync-any-protocol=1` | Убрать `--filter-l7=` |
| `--dpi-desync-cutoff=n2` | `--out-range=-p2` |
| `--wf-tcp=80,443` | Не нужен (nftables) |

### Полный пример перевода

**Flowseal** (из `general (FAKE TLS AUTO ALT2).bat`):
```bat
--filter-tcp=443 --hostlist="%LISTS%list-google.txt" --ip-id=zero
  --dpi-desync=fake,multisplit
  --dpi-desync-split-seqovl=681 --dpi-desync-split-pos=1
  --dpi-desync-fooling=badseq --dpi-desync-badseq-increment=10000000
  --dpi-desync-repeats=8
  --dpi-desync-split-seqovl-pattern="%BIN%tls_clienthello_www_google_com.bin"
  --dpi-desync-fake-tls-mod=rnd,dupsid,sni=www.google.com
```

**zapret2**:
```bash
# Blob (загружается один раз глобально):
--blob=tls_google:@/opt/zapret2/files/fake/tls_clienthello_www_google_com.bin

# Профиль:
--filter-tcp=443 --filter-l7=tls --hostlist=$LISTS_DIR/list-google.txt --payload=tls_client_hello \
  --lua-desync=fake:blob=fake_default_tls:tcp_seq=10000000:repeats=8:tls_mod=rnd,dupsid,sni=www.google.com:ip_id=zero \
  --lua-desync=multisplit:pos=1:seqovl=681:seqovl_pattern=tls_google:ip_id=zero
```

Что изменилось:
- `--dpi-desync=fake,multisplit` → два отдельных `--lua-desync=fake:...` и `--lua-desync=multisplit:...`
- `--dpi-desync-fooling=badseq --dpi-desync-badseq-increment=10000000` → `tcp_seq=10000000` (аргумент fake)
- `--dpi-desync-split-seqovl=681` → `seqovl=681` (аргумент multisplit)
- `--dpi-desync-split-seqovl-pattern="%BIN%file.bin"` → `seqovl_pattern=tls_google` (ссылка на blob)
- `--dpi-desync-fake-tls-mod=rnd,dupsid,sni=www.google.com` → `tls_mod=rnd,dupsid,sni=www.google.com` (аргумент fake)
- `--ip-id=zero` → `ip_id=zero` (аргумент каждой lua-desync функции)
- Добавлены `--filter-l7=tls` и `--payload=tls_client_hello` (zapret2 требует явный L7-фильтр)

---

## 9. systemd-сервис

```ini
[Unit]
Description=Zapret2 DPI Bypass (NAT Router Mode)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/opt/zapret-scripts
ExecStart=/usr/bin/env bash /opt/zapret-scripts/main_script.sh
ExecStop=/usr/bin/env bash /opt/zapret-scripts/stop_and_clean_nft.sh
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

Установка:
```bash
sudo cp zapret_discord_youtube.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now zapret_discord_youtube
```

---

## 10. Критические грабли

### `pkill -f nfqws2` убивает SSH-сессию

**Проблема**: `pkill -f nfqws2` ищет "nfqws2" в ПОЛНОЙ командной строке любого процесса.
Если вы подключены через `ssh root@host "... nfqws2 ..."`, SSH-сессия тоже содержит "nfqws2".

**Решение**: Всегда `pkill -x nfqws2` (точное совпадение имени бинарника).

### nftables `!=` в bash double quotes

**Проблема**: `sudo nft add rule ... "mark and $FWMARK != 0x00000000 notrack"` — bash
раскрывает `!` в двойных кавычках как history expansion.

**Решение**: Не оборачивать в кавычки:
```bash
sudo nft add rule $table_name predefrag mark and $FWMARK != 0x00000000 notrack
```

### dnsmasq падает при загрузке: "unknown interface eth0"

**Проблема**: dnsmasq с `bind-interfaces` стартует раньше чем NetworkManager поднимет eth0.

**Решение**: Использовать `bind-dynamic` вместо `bind-interfaces` в `/etc/dnsmasq.d/lan.conf`.
`bind-dynamic` ждёт появления интерфейса.

### WAN DHCP timeout при миграции с bridge

**Проблема**: Удаление bridge и активация WAN при подключённых кабелях → DHCP timeout.

**Решение**: Конфигурируй всё с отключёнными кабелями, потом физически подключай.

### DMZ IP не совпадает с DHCP-адресом роутера

**Проблема**: nftables `dnat to 10.10.10.2`, но роутер получил `10.10.10.190` по DHCP.

**Решение**: Добавить статический DHCP lease для MAC роутера в dnsmasq:
```
dhcp-host=AA:BB:CC:DD:EE:FF,10.10.10.190,router
```
Проверить текущий lease: `cat /var/lib/misc/dnsmasq.leases`

### Конфликт имён blob

**Проблема**: `--blob=fake_default_quic:@path` → "duplicate blob name" потому что
`fake_default_quic` — встроенное имя.

**Решение**: Использовать свои имена: `--blob=quic_google:@path`.
Зарезервированные имена: `fake_default_tls`, `fake_default_http`, `fake_default_quic`.

### nfqws2 работает локально, но не для forwarded-трафика

**Проблема**: `curl https://youtube.com` работает с самого Orange Pi, но не с клиентов за роутером.

**Решение**: nftables postnat chain должен иметь `priority srcnat + 1` (не просто `srcnat`).
`+1` гарантирует что nfqws2 видит трафик ПОСЛЕ masquerade.

---

## 11. Диагностика

```bash
# 1. nfqws2 запущен?
ps aux | grep nfqws2

# 2. nftables правила на месте?
sudo nft list ruleset

# 3. Трафик попадает в очередь? (ненулевые счётчики после теста)
sudo nft list ruleset | grep -E "packets [1-9]"

# 4. Какая стратегия загружена?
journalctl -u zapret_discord_youtube | grep "Loaded strategy"

# 5. Тест с самого устройства
curl -s --max-time 10 -o /dev/null -w '%{http_code} %{time_total}s\n' https://youtube.com

# 6. NAT работает? (внешний IP)
curl -s ifconfig.me

# 7. DMZ работает? (DNAT-правило)
sudo nft list table ip nat

# 8. DHCP-leases
cat /var/lib/misc/dnsmasq.leases

# 9. Отладка nfqws2 (запуск в foreground без --daemon)
sudo /opt/zapret2/nfq2/nfqws2 --bind-fix4 --fwmark=0x40000000 --qnum=220 \
  --lua-init=@/opt/zapret2/lua/zapret-lib.lua \
  --lua-init=@/opt/zapret2/lua/zapret-antidpi.lua \
  --filter-tcp=443 --filter-l7=tls \
  --lua-desync=fake:blob=fake_default_tls:tcp_seq=10000000
# Смотри stdout — какие профили матчатся, какие desync-действия выполняются
```

---

## 12. Чеклист после развёртывания

### Первичная настройка
- [ ] `nat-setup.sh` выполнен без ошибок
- [ ] `nmcli con show --active` показывает wan, lan (и wlan0 если есть)
- [ ] `systemctl is-active dnsmasq` → active
- [ ] Роутер получил IP: `cat /var/lib/misc/dnsmasq.leases`
- [ ] `curl ifconfig.me` возвращает IP провайдера
- [ ] `conf.env` содержит правильные интерфейсы, IP роутера, имя стратегии
- [ ] Файл стратегии существует в `strategies/`
- [ ] `systemctl start zapret_discord_youtube` → без ошибок
- [ ] `ps aux | grep nfqws2` → процесс запущен
- [ ] `sudo nft list tables` → `table ip nat` + `table inet zapretunix`

### Тесты DPI bypass
- [ ] `curl -s --max-time 10 https://youtube.com` → HTTP 200
- [ ] `curl -s --max-time 10 https://discord.com` → HTTP 200
- [ ] YouTube работает из браузера клиента за роутером
- [ ] Discord работает из браузера клиента за роутером
- [ ] `sudo nft list ruleset | grep -E "packets [1-9]"` → ненулевые счётчики

### После перезагрузки
- [ ] `systemctl is-active dnsmasq` → active
- [ ] `systemctl is-active zapret_discord_youtube` → active
- [ ] `ps aux | grep nfqws2` → процесс запущен
- [ ] `sudo nft list tables` → обе таблицы на месте
- [ ] YouTube + Discord работают
