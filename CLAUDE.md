# Orange Pi 3B — NAT Router для DPI Bypass (zapret2)

## Цель проекта

Orange Pi 3B работает как NAT-роутер между провайдером и Keenetic KN-3710.
Весь трафик проходит через Orange Pi для DPI bypass (zapret2/nfqws2).
Keenetic находится в DMZ — получает все входящие соединения.

## Схема сети

```
Провайдер → Конвертер → [enx00e04c176c60] (WAN, DHCP от провайдера)
                              ↓
                        Orange Pi (NAT-роутер, 10.10.10.1)
                              ↓
                         [eth0] (LAN, 10.10.10.1/24, DHCP-сервер)
                              ↓
                        Keenetic KN-3710 (10.10.10.2, DMZ)
                              ↓
                        Клиенты (WiFi + LAN)

wlan0 (192.168.1.73) ← SSH-управление Orange Pi через WiFi Keenetic
```

## Система

- **Плата:** Orange Pi 3B (Rockchip RK3566)
- **ОС:** Orange Pi 1.0.4 Jammy (Ubuntu 22.04)
- **Ядро:** Linux 5.10.160-rockchip-rk356x
- **Сеть:** NetworkManager
- **DPI bypass:** zapret2 (nfqws2 + Lua)

## Сетевые интерфейсы

| Интерфейс | Тип | MAC | Роль |
|-----------|-----|-----|------|
| `enx00e04c176c60` | USB RTL8153 | 00:e0:4c:17:6c:60 | WAN — к конвертеру провайдера |
| `eth0` | Встроенный Gigabit | 00:00:a4:4e:fd:fb | LAN — к Keenetic (10.10.10.1/24) |
| `wlan0` | WiFi | e0:51:d8:67:67:10 | SSH-управление (DHCP от Keenetic) |

## Конфигурация NAT

### Первоначальная настройка

Запустить один раз: `sudo bash nat-setup.sh`

Скрипт:
1. Удаляет старый bridge (br0)
2. Настраивает WAN (DHCP) и LAN (10.10.10.1/24) через nmcli
3. Включает IP forwarding
4. Устанавливает dnsmasq (DHCP-сервер на eth0)

### nftables (автоматически через main_script.sh)

- **NAT таблица** (`ip nat`): masquerade + DMZ DNAT на Keenetic
- **zapret2 таблица** (`inet zapretunix`): POSTNAT-схема
  - `postnat` chain — перехват исходящего трафика после NAT
  - `pre` chain — перехват входящего (для wssize cutoff, SYN+ACK)
  - `predefrag` chain — notrack для пакетов от nfqws2

## zapret2 (DPI bypass)

**Бинарник:** `/opt/zapret2/nfq2/nfqws2`
**Lua-скрипты:** `/opt/zapret2/lua/`
**Fake-файлы:** `/opt/zapret2/files/fake/`

### Стратегия (NAT mode)

В NAT-режиме доступны все техники (в отличие от bridge):
- `fake` — fake-пакеты с tcp_md5 fooling
- `multisplit` с `seqovl` — sequence overlap (DPI видит fake, сервер игнорирует)
- `wssize` с работающим cutoff (incoming трафик через prerouting)

Стратегия встроена в `main_script.sh` → функция `start_nfqws2()`.

### Покрытие сервисов

| Сервис | Протокол | Порты | Метод |
|--------|----------|-------|-------|
| YouTube | TLS/QUIC | TCP 443, UDP 443 | fake + multisplit + seqovl |
| Discord | TLS/QUIC/голос | TCP 443/2053/…, UDP 19294-19344/50000-50100 | fake + multisplit |
| Telegram (сообщения) | MTProto/TLS | TCP 443 | fake + multisplit (ipset-telegram.txt) |
| Telegram (звонки) | STUN/UDP | UDP 590-1400, 3478 | fake (stun.bin) |
| MTProto-прокси | TCP | TCP 49312 | fake + multisplit |

### Пользовательские IP-листы

`lists/ipset-telegram.txt` — IP-диапазоны Telegram DC1-DC5, хранится в репозитории.
Переменная `TELEGRAM_IPSET=$BASE_DIR/lists/ipset-telegram.txt` задаётся в стратегии.

### Запуск/остановка

```bash
# Через systemd
systemctl start zapret_discord_youtube
systemctl stop zapret_discord_youtube

# Вручную
sudo bash main_script.sh
sudo bash stop_and_clean_nft.sh
```

## WiFi (wlan0)

WiFi **отдельный** от NAT, получает IP по DHCP от Keenetic для SSH-доступа.
Текущее подключение: `192.168.1.73`

## Резервный план

Если Orange Pi выключен — сеть не работает. Держать под рукой патч-корд
для прямого соединения конвертера с Keenetic.

## Полезные команды

```bash
# Состояние интерфейсов
ip link show
ip addr show

# nftables правила
sudo nft list ruleset

# Счётчики трафика zapret2
sudo nft list table inet zapretunix

# nfqws2 процесс
ps aux | grep nfqws2

# Мониторинг трафика
iftop -i enx00e04c176c60
tcpdump -i enx00e04c176c60 -n 'tcp port 443 and ttl < 10'

# DHCP leases
cat /var/lib/misc/dnsmasq.leases

# Логи NetworkManager
journalctl -u NetworkManager -f
```

## Траблшутинг: сервис/приложение не работает через zapret

Когда пользователь сообщает что какой-то сервис (Steam, игра, сайт) не работает или работает медленно — следуй этому порядку:

### 1. Определи причину: zapret ломает или провайдер блокирует?

Спроси пользователя: **работает ли сервис при выключенном zapret?**
- **Да (без zapret работает)** → zapret ломает трафик сервиса → нужно **исключить** сервис из обработки
- **Нет (не работает и без zapret)** → блокировка провайдера/РКН → нужно **добавить** обход DPI для сервиса

### 2. Поищи в GitHub issues

Поищи проблему в issues этих репозиториев (через `gh search issues` или веб-поиск):
- **Flowseal**: `gh search issues --repo Flowseal/zapret-discord-youtube "<сервис>"`
- **zapret2**: `gh search issues --repo bol-van/zapret2 "<сервис>"`
- **zapret (v1)**: `gh search issues --repo bol-van/zapret "<сервис>"`

Там часто есть готовые решения: какие домены/IP исключить, какие порты добавить, какую стратегию использовать.

### 3a. Если zapret ломает сервис → исключить из обработки

Типичная причина: IP-адреса сервиса попали в `ipset-all.txt` от Flowseal.

1. Найди IP-диапазоны сервиса (ASN lookup, issues, `nslookup`)
2. Проверь пересечение: `grep '<prefix>' /opt/zapret-scripts/zapret-latest/lists/ipset-all.txt`
3. Добавь домены в `zapret-latest/lists/list-exclude.txt`
4. Добавь IP-диапазоны в `zapret-latest/lists/ipset-exclude.txt`
5. `systemctl restart zapret_discord_youtube`

Exclude-файлы читаются правилами стратегии с `--hostlist-exclude` и `--ipset-exclude`.

### 3b. Если блокирует провайдер → добавить обход DPI

1. Определи протоколы и порты сервиса (из issues или документации)
2. Добавь правила в стратегию (`strategies/*.sh`): `--filter-tcp`/`--filter-udp` + `--lua-desync`
3. Если нужен IP-лист — создай в `lists/` (отслеживается git), не в `zapret-latest/lists/` (gitignored)
4. Обнови `TCP_PORTS`/`UDP_PORTS` в стратегии
5. Задеплой и перезапусти сервис

### Пример: Steam (решено)

Steam ломался при включённом zapret. Причина: IP Valve (AS32590) были в `ipset-all.txt`.
Решение: добавлены домены `steampowered.com`, `steamcommunity.com`, ... в `list-exclude.txt`
и IP-диапазоны 155.133.x.x, 162.254.x.x, 208.x.x.x в `ipset-exclude.txt`.

## Известные проблемы

- **USB-адаптер не определяется после перезагрузки:** выполнить `usb_modeswitch` или физически переподключить
- **Низкая скорость:** убедиться что USB-адаптер в USB 3.0 порту (синий)
- **Ошибки Tx timeout:** `ethtool -K enx00e04c176c60 tx off`
- **Steam не работает:** IP Valve попадают в `ipset-all.txt` Flowseal — добавить в `ipset-exclude.txt` (см. траблшутинг выше)
