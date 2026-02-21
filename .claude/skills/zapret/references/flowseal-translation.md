# Flowseal .bat → zapret2: полная таблица маппинга

## Принципы перевода

1. **Comma-separated техники → отдельные `--lua-desync`**:
   ```
   Flowseal:  --dpi-desync=fake,multisplit --dpi-desync-split-seqovl=681
   zapret2:   --lua-desync=fake:blob=...:repeats=8 --lua-desync=multisplit:pos=1:seqovl=681
   ```

2. **Файлы → blob-имена**: Flowseal ссылается на файлы (`"%BIN%file.bin"`).
   zapret2 загружает blob'ы глобально (`--blob=name:@path`), потом ссылается по имени (`blob=name`).

3. **Глобальный fooling → per-function args**: Flowseal `--dpi-desync-fooling=badseq` применяется
   ко всему профилю. В zapret2 fooling-аргументы идут на каждый `--lua-desync` отдельно.

4. **Фильтр портов**: Flowseal `--wf-tcp=`/`--wf-udp=` не нужны в Linux (nftables фильтрует порты).
   Но `--filter-tcp=`/`--filter-udp=` внутри профиля — нужны (это per-profile matching внутри nfqws2).

5. **`--new` разделители**: маппятся 1:1 между Flowseal и zapret2.

## Таблица параметров

| Flowseal (nfqws1) | zapret2 (nfqws2) |
|-------------------|-------------------|
| `--dpi-desync=fake,multisplit` | `--lua-desync=fake:... --lua-desync=multisplit:...` |
| `--dpi-desync=fake` | `--lua-desync=fake:blob=fake_default_tls:badsum` |
| `--dpi-desync=multisplit` | `--lua-desync=multisplit:pos=1,sniext+1` |
| `--dpi-desync=multidisorder` | `--lua-desync=multidisorder:pos=1,midsld` |
| `--dpi-desync=fakedsplit` | `--lua-desync=fakedsplit:pos=sniext+1:badsum` |
| `--dpi-desync=fakeddisorder` | `--lua-desync=fakeddisorder:pos=sniext+1:badsum` |
| `--dpi-desync-split-seqovl=681` | `seqovl=681` (аргумент multisplit) |
| `--dpi-desync-split-pos=1` | `pos=1` (аргумент multisplit) |
| `--dpi-desync-fooling=badsum` | `badsum` |
| `--dpi-desync-fooling=md5sig` | `tcp_md5` |
| `--dpi-desync-fooling=badseq` | `tcp_seq=N` (в zapret2 нет отдельного badseq — seq задаётся числом) |
| `--dpi-desync-badseq-increment=10000000` | `tcp_seq=10000000` |
| `--dpi-desync-ttl=8` | `ip_ttl=8` |
| `--dpi-desync-autottl=4` | `ip_autottl=4,1-64` |
| `--dpi-desync-repeats=8` | `repeats=8` (аргумент fake) |
| `--dpi-desync-split-seqovl-pattern="file.bin"` | `seqovl_pattern=blob_name` (загрузить файл как blob) |
| `--dpi-desync-fake-tls-mod=rnd,dupsid,sni=X` | `tls_mod=rnd,dupsid,sni=X` (аргумент fake) |
| `--dpi-desync-fake-quic="file.bin"` | `--blob=name:@file` + `blob=name` в fake |
| `--dpi-desync-fake-http="file.bin"` | Аналогично: загрузить как blob, ссылаться по имени |
| `--ip-id=zero` | `ip_id=zero` (аргумент каждой lua-desync функции) |
| `--dpi-desync-any-protocol=1` | Убрать `--filter-l7=` (матчить любой протокол) |
| `--dpi-desync-cutoff=n2` | `--out-range=-p2` (ограничить desync первыми 2 payload-пакетами) |
| `--hostlist="file"` | `--hostlist=file` (без изменений) |
| `--wsize=1 --wscale=6` | `--lua-desync=wsize:wsize=1:scale=6` |
| `--wf-tcp=80,443` | Не нужен (nftables) |
| `--wf-udp=443` | Не нужен (nftables) |

## Замечания по `repeats`

В Flowseal `--dpi-desync-repeats=N` применяется ко всем техникам в профиле. В zapret2:
- `repeats=N` на `fake` — сколько fake-пакетов отправить
- `repeats=N` на `multisplit` — НЕ поддерживается (multisplit не повторяет сегменты)
- При переводе `fake,multisplit` ставь `repeats=N` только на `fake`

## Полный пример перевода

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
- `--dpi-desync=fake,multisplit` → два `--lua-desync=`
- `--dpi-desync-fooling=badseq` + `increment=10000000` → `tcp_seq=10000000` на fake
- `--dpi-desync-split-seqovl=681` → `seqovl=681` на multisplit
- `--dpi-desync-split-seqovl-pattern` → blob `tls_google` + `seqovl_pattern=tls_google`
- `--dpi-desync-fake-tls-mod` → `tls_mod=` на fake
- `--ip-id=zero` → `ip_id=zero` на каждой функции
- Добавлены `--filter-l7=tls` и `--payload=tls_client_hello`
