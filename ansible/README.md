# Ansible playbook — Orange Pi NAT Router

Полное развёртывание Orange Pi 3B как NAT-роутера с zapret2 DPI bypass и DoH DNS.

## Требования

```bash
pip install ansible
ansible-galaxy collection install -r requirements.yml
```

## Быстрый старт

```bash
cd ansible/

# Полное развёртывание
ansible-playbook -i inventory.yml playbook.yml

# Только одна роль
ansible-playbook -i inventory.yml playbook.yml --tags dnsproxy

# Dry run
ansible-playbook -i inventory.yml playbook.yml --check
```

## Переменные

Все переменные в `group_vars/orangepi.yml`. Ключевые:

| Переменная | Назначение |
|------------|------------|
| `wan_iface` / `lan_iface` | Сетевые интерфейсы |
| `keenetic_mac` / `keenetic_ip` | Статический DHCP-lease для роутера |
| `ssh_listen_ip` | IP wlan0 — SSH будет слушать только здесь |
| `doh_url` | Провайдер DNS over HTTPS |
| `active_strategy` | Имя файла стратегии zapret (без .sh) |

## Роли

| Роль | Что делает |
|------|------------|
| `system` | Пакеты, sysctl IP forwarding, отключение adbd/rpcbind |
| `network` | nmcli WAN (DHCP) + LAN (10.10.10.1/24) |
| `security` | SSH только на wlan0 |
| `dnsmasq` | DHCP-сервер + DNS forwarder → dnsproxy |
| `dnsproxy` | DoH-клиент (AdGuard dnsproxy) на 127.0.0.1:5353 |
| `zapret2` | Установка nfqws2 из исходников |
| `zapret_scripts` | Деплой проекта + Flowseal lists + systemd service |

## Что НЕ автоматизируется

- Физическое подключение кабелей (WAN, LAN)
- Добавление SSH-ключа в `authorized_keys`
- Первая загрузка после смены сетевых настроек

## Проверка после деплоя

```bash
ansible orangepi -i inventory.yml -m command -a \
  "systemctl is-active zapret_discord_youtube dnsproxy dnsmasq"

ansible orangepi -i inventory.yml -m command -a \
  "dig @10.10.10.1 google.com +short"
```
