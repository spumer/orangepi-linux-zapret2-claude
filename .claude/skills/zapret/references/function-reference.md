# Справочник функций zapret-antidpi.lua

Все функции вызываются через `--lua-desync=funcname:arg1=val1:arg2:arg3=val3`.
Аргументы разделяются двоеточиями. Булевые флаги без `=` (просто имя).

## Fooling-аргументы (общие для многих функций)

| Аргумент | Описание |
|----------|----------|
| `badsum` | Плохая L4 контрольная сумма — ОС дропает, DPI может принять |
| `ip_ttl=N` | Установить IPv4 TTL |
| `ip_autottl=delta,min-max` | Автоопределение TTL с вычитанием delta |
| `tcp_seq=N` | Сдвинуть TCP sequence на N (напр. `tcp_seq=10000000`) |
| `tcp_md5` | Добавить TCP MD5 signature option |
| `tcp_ts=N` | Сдвинуть TCP timestamp на N |
| `ip6_hopbyhop[=hex]` | Добавить IPv6 hop-by-hop заголовок |

## Position markers (аргумент `pos=`)

| Маркер | Значение |
|--------|----------|
| `N` | Байтовое смещение N (с 1) |
| `-N` | N байт от конца |
| `method` / `method+2` | Начало HTTP-метода / после метода |
| `host` / `endhost` | Начало / конец hostname |
| `midsld` | Середина second-level домена |
| `sniext` / `sniext+1` | Конец TLS SNI extension / +1 байт после |

## Основные функции

### fake — инъекция фейкового пакета
```
--lua-desync=fake:blob=fake_default_tls:tcp_seq=10000000:repeats=8:tls_mod=rnd,dupsid,sni=www.google.com
```
- `blob=<name>` — фейковый payload (обязателен). Встроенные: `fake_default_tls`, `fake_default_http`, `fake_default_quic`
- `tls_mod=rnd,rndsni,sni=<str>,dupsid,padencap` — модификация TLS hello в фейке
- `repeats=N` — сколько фейков отправить
- Все fooling-аргументы

### multisplit — разделение payload на TCP-сегменты
```
--lua-desync=multisplit:pos=1,midsld:seqovl=681:seqovl_pattern=tls_google
```
- `pos=<markers>` — позиции разделения (через запятую)
- `seqovl=N` — overlap N байт (DPI видит fake-данные в зоне overlap)
- `seqovl_pattern=<blob>` — чем заполнить overlap

### multidisorder — split + отправка сегментов в обратном порядке
Те же аргументы что у multisplit. **Работает на bridge** (в отличие от fake).

### fakedsplit — split + фейковые пакеты вокруг каждого сегмента
```
--lua-desync=fakedsplit:pos=sniext+1:badsum:repeats=4
```
- `nofake1`..`nofake4` — подавить конкретные фейки

### fakeddisorder — fakedsplit + второй сегмент отправляется первым

### wssize / wsize — перезапись размера TCP-окна
```
--lua-desync=wssize:wsize=1:scale=6
```
Применяется на SYN до SNI — не domain-specific. Для поздней блокировки (Discord 10KB stall).

### syndata — инъекция данных в SYN
### udplen — изменение длины UDP
### oob — Out-Of-Band urgent data

## Оркестрация (zapret-auto.lua)

### circular — ротация стратегий при отказе
```
--lua-desync=circular --lua-desync=fake:...:strategy=1 --lua-desync=multisplit:...:strategy=2
```
- `fails=N` — порог отказов до переключения (default: 3)
- Используется с `standard_failure_detector` (детекция ретрансмиссий, RST, HTTP-редиректов)
  и `standard_success_detector` (сброс счётчиков при успехе)
