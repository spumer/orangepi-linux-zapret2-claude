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

## Известные проблемы

- **USB-адаптер не определяется после перезагрузки:** выполнить `usb_modeswitch` или физически переподключить
- **Низкая скорость:** убедиться что USB-адаптер в USB 3.0 порту (синий)
- **Ошибки Tx timeout:** `ethtool -K enx00e04c176c60 tx off`
