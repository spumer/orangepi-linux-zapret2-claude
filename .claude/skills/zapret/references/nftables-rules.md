# nftables правила по платформам

## NAT Router (POSTNAT-схема — РЕКОМЕНДУЕТСЯ)

Три chain. Схема из zapret2 manual (lines 381-417).

```nft
table ip nat {
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    oifname "$WAN" masquerade
  }
  chain prerouting {
    type nat hook prerouting priority dstnat; policy accept;
    iifname "$WAN" ct state new dnat to $ROUTER_IP
  }
}

table inet zapretunix {
  # Исходящий после NAT (srcnat + 1 — видит реальные IP после masquerade)
  chain postnat {
    type filter hook postrouting priority srcnat + 1; policy accept;
    oifname "$WAN" meta mark & 0x40000000 == 0 tcp dport {80,443,...} \
      ct original packets 1-20 counter queue flags bypass to 220
    oifname "$WAN" meta mark & 0x40000000 == 0 udp dport {443,...} \
      ct original packets 1-5 counter queue flags bypass to 220
    oifname "$WAN" meta mark & 0x40000000 == 0 tcp dport {80,443,...} \
      tcp flags fin,rst counter queue flags bypass to 220
  }

  # Входящий (для wssize cutoff, перехват SYN+ACK)
  chain pre {
    type filter hook prerouting priority filter; policy accept;
    iifname "$WAN" tcp sport {80,443,...} ct reply packets 1-15 \
      counter queue flags bypass to 220
    iifname "$WAN" tcp sport {80,443,...} tcp flags syn,ack / syn,ack \
      counter queue flags bypass to 220
    iifname "$WAN" tcp sport {80,443,...} tcp flags fin,rst \
      counter queue flags bypass to 220
    iifname "$WAN" udp sport {443,...} ct reply packets 1-3 \
      counter queue flags bypass to 220
  }

  # notrack для пакетов nfqws2 (предотвращает дроп NAT'ом модифицированных пакетов)
  chain predefrag {
    type filter hook output priority -401; policy accept;
    meta mark & 0x40000000 != 0 notrack
  }
}
```

**Ключевые параметры:**
- `priority srcnat + 1` — ОБЯЗАТЕЛЬНО +1, иначе nfqws2 не видит post-NAT трафик
- `ct original packets 1-20` — только первые 20 пакетов каждого потока (экономия CPU)
- `queue flags bypass to 220` — если nfqws2 не запущен, трафик проходит без изменений
- `0x40000000` — fwmark, которым nfqws2 маркирует свои пакеты (защита от петли)

## Transparent Bridge (FORWARD chain)

```nft
# ТРЕБУЕТ: modprobe br_netfilter && sysctl net.bridge.bridge-nf-call-iptables=1

table inet zapret {
  chain forward {
    type filter hook forward priority filter; policy accept;
    meta mark & 0x40000000 != 0 return
    oifname "$WAN" tcp dport {80,443} ct original packets 1-20 queue num 200 bypass
    oifname "$WAN" udp dport {443} ct original packets 1-5 queue num 200 bypass
    oifname "$WAN" tcp dport {80,443} tcp flags & (fin|rst) != 0 queue num 200 bypass
    iifname "$WAN" tcp sport {80,443} ct reply packets 1-10 queue num 200 bypass
    iifname "$WAN" tcp sport {80,443} tcp flags & (syn|ack) == (syn|ack) queue num 200 bypass
    iifname "$WAN" tcp sport {80,443} tcp flags & (fin|rst) != 0 queue num 200 bypass
  }
  chain output_defrag {
    type filter hook output priority -401;
    mark and 0x40000000 != 0 notrack
  }
}
```

**Помни**: на мосту работают только multisplit/multidisorder. fake/seqovl неэффективны.

## Windows (winws2)

WinDivert заменяет nftables. Фильтры — аргументы командной строки:
```
winws2 --wf-tcp=80,443 --wf-udp=443 --lua-init=... --lua-desync=...
```
