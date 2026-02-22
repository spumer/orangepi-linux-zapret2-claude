# Orange Pi NAT Router + zapret2 DPI Bypass

[English](#english) | [Русский](#русский)

---

## English

Linux SBC (Orange Pi 3B) as a NAT router with DPI bypass via [zapret2](https://github.com/bol-van/zapret2) (nfqws2 + Lua).

### Topology

```
ISP → Media converter → [WAN] Orange Pi (NAT, 10.10.10.1/24) [LAN] → Router → Clients
                                              ↑
                                       wlan0 (SSH management)
```

Orange Pi handles:
- **NAT masquerade** — outgoing packets get the ISP's IP
- **DMZ DNAT** — all incoming connections forwarded to the downstream router
- **DPI bypass** — nfqws2 with POSTNAT scheme (fake + multisplit + seqovl)
- **DHCP server** — dnsmasq on the LAN interface

Bypassed services: **YouTube**, **Discord** (text + voice/video), **Telegram** (messages + calls + MTProto proxy).

### Why NAT instead of bridge?

On a transparent bridge, key DPI bypass techniques **do not work**: `fake`, `fakedsplit`, `seqovl`, `wssize`. The root cause is a timing mismatch between the raw socket (OUTPUT chain) and NF_ACCEPT (FORWARD chain). NAT mode eliminates this limitation — all zapret2 techniques are available.

Detailed bridge vs NAT comparison — in the [deployment guide](docs/deployment-guide.md#2-bridge-vs-nat-когда-что-выбирать).

### Project structure

```
main_script.sh              # NAT + nftables + nfqws2 launcher
strategies/                  # Modular DPI bypass strategies
  flowseal_fake_tls_auto_alt2.sh
lists/                       # Custom IP/domain lists (tracked in git)
  ipset-telegram.txt          # Telegram DC IP ranges
conf.env                     # Configuration (interfaces, IPs, active strategy)
nat-setup.sh                 # One-time network setup
stop_and_clean_nft.sh        # Stop nfqws2 and clean nftables
docs/deployment-guide.md     # Full deployment guide
.claude/skills/zapret/       # Claude Code skill for zapret2
```

### Quick start

#### 1. Install zapret2

```bash
cd /opt && git clone https://github.com/bol-van/zapret2.git && cd zapret2 && ./install_bin.sh
```

#### 2. Clone this repository

```bash
git clone https://github.com/spumer/orangepi-linux-zapret2-claude.git /opt/zapret-scripts
```

#### 3. Configure network (once)

Edit variables in `nat-setup.sh` for your interfaces, then:

```bash
sudo bash /opt/zapret-scripts/nat-setup.sh
sudo reboot
```

#### 4. Edit conf.env

```bash
wan_iface=enx00e04c176c60       # WAN interface name
lan_iface=eth0                  # LAN interface name
keenetic_ip=10.10.10.190        # Downstream router IP (DMZ target)
strategy=flowseal_fake_tls_auto_alt2
```

#### 5. Install systemd service

```bash
sudo cp zapret_discord_youtube.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now zapret_discord_youtube
```

#### 6. Verify

```bash
curl -s --max-time 10 -o /dev/null -w '%{http_code}\n' https://youtube.com   # 200
curl -s --max-time 10 -o /dev/null -w '%{http_code}\n' https://discord.com   # 200
curl -s --max-time 10 -o /dev/null -w '%{http_code}\n' https://web.telegram.org  # 200
```

### Strategies

Strategies are `.sh` files in `strategies/`. Each defines `BLOB_OPTS`, `STRATEGY`, and optionally `TCP_PORTS`/`UDP_PORTS`.

Switching:
```bash
# Edit strategy= in conf.env
sudo systemctl restart zapret_discord_youtube
```

More on creating strategies and translating Flowseal .bat → zapret2 — in the [deployment guide](docs/deployment-guide.md#7-создание-и-адаптация-стратегий).

### Documentation

- **[Deployment Guide](docs/deployment-guide.md)** — full instructions: topology, bridge vs NAT, network setup, strategies, Flowseal translation, gotchas, diagnostics
- **[Claude Skill](.claude/skills/zapret/SKILL.md)** — Claude Code skill with zapret2 knowledge base

### Troubleshooting: service doesn't work through zapret

If a service (game, website, app) breaks or slows down:

1. **Check if it works without zapret** (`systemctl stop zapret_discord_youtube`)
   - Works without zapret → zapret is breaking it → **exclude** the service
   - Broken with or without → ISP/RKN blocking → **add** DPI bypass rules

2. **Search GitHub issues** for known solutions:
   - [Flowseal issues](https://github.com/Flowseal/zapret-discord-youtube/issues) — most common problems are already solved
   - [zapret2 issues](https://github.com/bol-van/zapret2/issues)
   - [zapret (v1) issues](https://github.com/bol-van/zapret/issues)

3. **If zapret breaks the service** — exclude from processing:
   - Find service IPs: `grep '<ip_prefix>' zapret-latest/lists/ipset-all.txt`
   - Add domains to `zapret-latest/lists/list-exclude.txt`
   - Add IP ranges to `zapret-latest/lists/ipset-exclude.txt`
   - `systemctl restart zapret_discord_youtube`

4. **If ISP blocks the service** — add bypass rules to the strategy (see [deployment guide](docs/deployment-guide.md))

### Requirements

- Linux SBC with 2 ethernet interfaces
- Ubuntu/Debian with NetworkManager
- [zapret2](https://github.com/bol-van/zapret2) installed at `/opt/zapret2/`
- Domain/IP lists (Flowseal or custom) in `zapret-latest/lists/`

---

## Русский

Linux SBC (Orange Pi 3B) как NAT-роутер с обходом DPI через [zapret2](https://github.com/bol-van/zapret2) (nfqws2 + Lua).

### Топология

```
Провайдер → Конвертер → [WAN] Orange Pi (NAT, 10.10.10.1/24) [LAN] → Роутер → Клиенты
                                          ↑
                                   wlan0 (SSH управление)
```

Orange Pi выполняет:
- **NAT masquerade** — все исходящие пакеты получают IP провайдера
- **DMZ DNAT** — все входящие соединения → роутер
- **DPI bypass** — nfqws2 с POSTNAT-схемой (fake + multisplit + seqovl)
- **DHCP-сервер** — dnsmasq на LAN-интерфейсе

Обходимые сервисы: **YouTube**, **Discord** (текст + голос/видео), **Telegram** (сообщения + звонки + MTProto-прокси).

### Почему NAT, а не bridge?

На прозрачном мосту (bridge) **не работают** ключевые техники обхода DPI: `fake`, `fakedsplit`, `seqovl`, `wssize`. Причина — разница тайминга между raw socket (OUTPUT) и NF_ACCEPT (FORWARD). NAT-режим снимает это ограничение, все техники zapret2 доступны.

Подробное сравнение bridge vs NAT — в [deployment guide](docs/deployment-guide.md#2-bridge-vs-nat-когда-что-выбирать).

### Структура

```
main_script.sh              # NAT + nftables + запуск nfqws2
strategies/                  # Стратегии DPI bypass (модульные)
  flowseal_fake_tls_auto_alt2.sh
lists/                       # Пользовательские IP/домен листы (в git)
  ipset-telegram.txt          # IP-диапазоны Telegram DC
conf.env                     # Конфигурация (интерфейсы, IP, активная стратегия)
nat-setup.sh                 # Одноразовая настройка сети
stop_and_clean_nft.sh        # Остановка и очистка
docs/deployment-guide.md     # Полная инструкция по развёртыванию
.claude/skills/zapret/       # Claude Code skill для работы с zapret2
```

### Быстрый старт

#### 1. Установить zapret2

```bash
cd /opt && git clone https://github.com/bol-van/zapret2.git && cd zapret2 && ./install_bin.sh
```

#### 2. Клонировать этот репозиторий

```bash
git clone https://github.com/spumer/orangepi-linux-zapret2-claude.git /opt/zapret-scripts
```

#### 3. Настроить сеть (один раз)

Отредактировать переменные в `nat-setup.sh` под свои интерфейсы, затем:

```bash
sudo bash /opt/zapret-scripts/nat-setup.sh
sudo reboot
```

#### 4. Настроить conf.env

```bash
wan_iface=enx00e04c176c60       # Имя WAN-интерфейса
lan_iface=eth0                  # Имя LAN-интерфейса
keenetic_ip=10.10.10.190        # IP роутера (DMZ)
strategy=flowseal_fake_tls_auto_alt2
```

#### 5. Установить systemd-сервис

```bash
sudo cp zapret_discord_youtube.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now zapret_discord_youtube
```

#### 6. Проверить

```bash
curl -s --max-time 10 -o /dev/null -w '%{http_code}\n' https://youtube.com   # 200
curl -s --max-time 10 -o /dev/null -w '%{http_code}\n' https://discord.com   # 200
curl -s --max-time 10 -o /dev/null -w '%{http_code}\n' https://web.telegram.org  # 200
```

### Стратегии

Стратегии — `.sh` файлы в `strategies/`. Каждая определяет `BLOB_OPTS`, `STRATEGY` и опционально `TCP_PORTS`/`UDP_PORTS`.

Переключение:
```bash
# Изменить strategy= в conf.env
sudo systemctl restart zapret_discord_youtube
```

Подробнее о создании стратегий и переводе Flowseal .bat → zapret2 — в [deployment guide](docs/deployment-guide.md#7-создание-и-адаптация-стратегий).

### Документация

- **[Deployment Guide](docs/deployment-guide.md)** — полная инструкция: топология, bridge vs NAT, настройка сети, стратегии, Telegram bypass, перевод Flowseal, грабли, диагностика
- **[Claude Skill](.claude/skills/zapret/SKILL.md)** — skill для Claude Code с knowledge base по zapret2

### Траблшутинг: сервис не работает через zapret

Если сервис (игра, сайт, приложение) перестаёт работать или тормозит:

1. **Проверь, работает ли без zapret** (`systemctl stop zapret_discord_youtube`)
   - Без zapret работает → zapret ломает трафик → нужно **исключить** сервис
   - Не работает и без zapret → блокировка провайдера/РКН → нужно **добавить** обход DPI

2. **Поищи в GitHub issues** — скорее всего решение уже есть:
   - [Flowseal issues](https://github.com/Flowseal/zapret-discord-youtube/issues) — самый частый источник решений
   - [zapret2 issues](https://github.com/bol-van/zapret2/issues)
   - [zapret (v1) issues](https://github.com/bol-van/zapret/issues)

3. **Если zapret ломает сервис** — исключить из обработки:
   - Найди IP сервиса: `grep '<префикс>' zapret-latest/lists/ipset-all.txt`
   - Добавь домены в `zapret-latest/lists/list-exclude.txt`
   - Добавь IP-диапазоны в `zapret-latest/lists/ipset-exclude.txt`
   - `systemctl restart zapret_discord_youtube`

4. **Если блокирует провайдер** — добавь правила обхода в стратегию (см. [deployment guide](docs/deployment-guide.md))

### Требования

- Linux SBC с 2 ethernet-интерфейсами
- Ubuntu/Debian с NetworkManager
- [zapret2](https://github.com/bol-van/zapret2) установлен в `/opt/zapret2/`
- Списки доменов/IP (Flowseal или свои) в `zapret-latest/lists/`
