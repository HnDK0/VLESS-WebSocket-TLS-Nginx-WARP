# VWN — Xray VLESS + WARP + CDN + Reality

Автоматический установщик Xray VLESS с поддержкой WebSocket+TLS, Reality, Cloudflare WARP, CDN, Relay, Psiphon, WARP-in-WARP и Tor.

## Быстрая установка

```bash
curl -L https://raw.githubusercontent.com/HnDK0/VLESS-WebSocket-TLS-Nginx-WARP/main/install.sh -o vwn && bash vwn
```

После установки скрипт доступен как команда:
```bash
vwn
```

Обновить модули (без изменения конфигов):
```bash
vwn update
```

## Требования

- Ubuntu 22.04+ / Debian 11+
- Root доступ
- Домен, направленный на сервер (для WS+TLS)
- Для Reality — только IP сервера, домен не нужен

## Особенности

- ✅ **VLESS + WebSocket + TLS** — подключения через Cloudflare CDN
- ✅ **VLESS + Reality** — прямые подключения без CDN (роутер, Clash)
- ✅ **Nginx** — reverse proxy с сайтом-заглушкой
- ✅ **Cloudflare WARP** — роутинг выбранных доменов или всего трафика
- ✅ **WARP-in-WARP** — второй WARP туннель (WireGuard) поверх первого
- ✅ **Psiphon** — обход блокировок с выбором страны выхода, опционально через WARP
- ✅ **Tor** — обход блокировок с выбором страны выхода, обновление цепи
- ✅ **Relay** — внешний outbound (VLESS/VMess/Trojan/SOCKS по ссылке)
- ✅ **CDN защита** — блокировка прямого доступа, только через Cloudflare
- ✅ **WARP Watchdog** — автовосстановление WARP при обрыве
- ✅ **Fail2Ban + Web-Jail** — защита от брутфорса и сканеров
- ✅ **BBR** — ускорение TCP
- ✅ **Anti-Ping** — отключение ICMP
- ✅ **IPv6 отключён системно** — принудительный IPv4
- ✅ **Приватность** — access логи отключены, sniffing выключен

## Архитектура

```
Клиент (CDN/мобильный)
    └── Cloudflare CDN → 443/HTTPS → Nginx → VLESS+WS → Xray → outbound

Клиент (роутер/Clash/прямое)
    └── IP:8443/TCP → VLESS+Reality → Xray → outbound

outbound (по routing rules):
    ├── free    — прямой выход (default)
    ├── warp    — Cloudflare WARP (SOCKS5:40000)
    ├── warp2   — WARP-in-WARP (SOCKS5:40001)
    ├── psiphon — Psiphon tunnel (SOCKS5:40002)
    ├── tor     — Tor (SOCKS5:40003)
    ├── relay   — внешний сервер (vless/vmess/trojan/socks)
    └── block   — blackhole (geoip:private)
```

## Порты

| Порт  | Назначение                        |
|-------|-----------------------------------|
| 22    | SSH (изменяемый)                  |
| 443   | VLESS+WS+TLS через Nginx          |
| 8443  | VLESS+Reality (по умолчанию)      |
| 40000 | WARP SOCKS5 (warp-cli, локальный) |
| 40001 | WARP2 SOCKS5 (xray-warp2, локальный) |
| 40002 | Psiphon SOCKS5 (локальный)        |
| 40003 | Tor SOCKS5 (локальный)            |
| 40004 | Tor Control Port (локальный)      |

## Меню управления

```
================================================================
   XRAY VLESS + WARP + CDN + REALITY | 27.02.2026 21:00
================================================================
  NGINX: RUNNING  |  XRAY: RUNNING  |  WARP: ACTIVE
  SSL: OK (89 d)  |  BBR: ON  |  F2B: OFF
  WebJail: NO  |  CDN: OFF  |  Reality: ON (порт 8443)
  Relay: OFF  |  Psiphon: ON (DE) via WARP  |  Tor: ON (US)  |  WARP2: ON
----------------------------------------------------------------
    1.  Установить Xray (VLESS+WS+TLS+WARP+CDN)
    2.  Показать QR-код и ссылку
    3.  Сменить UUID
    —————————————— Конфигурация —————————————
    4.  Изменить порт Xray
    5.  Изменить путь WebSocket
    6.  Изменить сайт-заглушку
    7.  Перевыпустить SSL сертификат
    8.  Сменить домен
    —————————————— CDN и WARP ———————————————
    9.  Переключить CDN режим (ON/OFF)
    10. Переключить режим WARP (Global/Split)
    11. Добавить домен в WARP
    12. Удалить домен из WARP
    13. Редактировать список WARP (Nano)
    14. Проверить IP (Real vs WARP)
    —————————————— Безопасность —————————————
    15. Включить BBR
    16. Включить Fail2Ban
    17. Включить Web-Jail
    18. Сменить SSH порт
    30. Установить WARP Watchdog
    —————————————— Логи —————————————————————
    19. Логи Xray (access)
    20. Логи Xray (error)
    21. Логи Nginx (access)
    22. Логи Nginx (error)
    23. Очистить все логи
    —————————————— Сервисы ——————————————————
    24. Перезапустить все сервисы
    25. Обновить Xray-core
    26. Полное удаление
    —————————————— UFW, SSL, Logs ———————————
    27. Управление UFW
    28. Управление автообновлением SSL
    29. Управление автоочисткой логов
    —————————————— Туннели ——————————————————
    31. Управление VLESS + Reality
    32. Управление Relay (внешний сервер)
    33. Управление Psiphon
    34. Управление Tor
    35. Управление WARP-in-WARP
    —————————————— Выход ————————————————————
    0.  Выйти
----------------------------------------------------------------
```

## Туннели (пункты 31–35)

Все туннели работают по одинаковой схеме:
- **Global режим** — весь трафик через туннель
- **Split режим** — только домены из списка
- Применяются одновременно к обоим конфигам (WS и Reality)

### VLESS + Reality (пункт 31)

Прямые подключения без CDN. Работает как отдельный сервис `xray-reality`.

```
vless://UUID@IP:8443?security=reality&sni=microsoft.com&fp=chrome&pbk=KEY&sid=SID&type=tcp&flow=xtls-rprx-vision
```

### Relay — внешний сервер (пункт 32)

Перенаправление трафика через внешний сервер. Поддерживает протоколы по ссылке:
```
vless://...  vmess://...  trojan://...  socks5://...
```

### Psiphon (пункт 33)

Обход блокировок с выбором страны выхода (DE, NL, US, GB, FR, AT, CA, SE и др.).

**Режимы запуска:**
- **Прямое подключение** — стандартный режим
- **Через WARP** — трафик Psiphon заворачивается через WARP1 (proxychains4), помогает если Psiphon блокируется провайдером сервера

Переключение режима без переустановки — пункт 10 в подменю.

### Tor (пункт 34)

Обход блокировок с выбором страны выхода через `ExitNodes`.

**Дополнительно:**
- **Обновить цепь** — запросить новый IP без перезапуска Tor
- Проверка IP с определением страны выхода

**Рекомендация:** использовать Split режим — Tor медленнее обычного интернета.

### WARP-in-WARP (пункт 35)

Второй независимый WARP туннель через WireGuard (`wgcf`). Трафик к Cloudflare WG endpoint идёт через первый WARP.

**Цепочка:** `Xray → SOCKS5:40001 → xray-warp2 (fwmark) → warp2 WireGuard → Cloudflare`

**Требование:** первый WARP должен быть активен.

**Примечание:** страну выхода выбрать нельзя — Cloudflare назначает сам.

## WARP (пункты 10–14)

**Split режим** (по умолчанию) — только выбранные домены через WARP:
```
openai.com, chatgpt.com, oaistatic.com, oaiusercontent.com, auth0.openai.com
```

**Global режим** — весь трафик через WARP.

**WARP Watchdog (пункт 30)** — cron каждые 2 минуты, автопереподключение при обрыве.

## SSL сертификаты

**Метод 1 — Cloudflare DNS API** (рекомендуется): порт 80 не нужен, требуются Email и Global API Key.

**Метод 2 — Standalone**: временно открывает порт 80, API ключи не нужны.

Автообновление через `/etc/cron.d/acme-renew` — раз в 35 дней в 3:00.

## CDN режим (пункт 9)

При включении скачиваются актуальные IP Cloudflare, прямой доступ к серверу блокируется (`return 444`), доступ только через Cloudflare Proxy. Включайте только после настройки домена с оранжевым облаком в Cloudflare.

## Структура файлов

```
/usr/local/lib/vwn/          # Модули
├── core.sh                  # Переменные, утилиты, статусы
├── xray.sh                  # Xray WS+TLS конфиг
├── nginx.sh                 # Nginx, CDN, SSL
├── warp.sh                  # WARP управление
├── warp2.sh                 # WARP-in-WARP (WireGuard)
├── reality.sh               # VLESS+Reality
├── relay.sh                 # Внешний outbound
├── psiphon.sh               # Psiphon туннель
├── tor.sh                   # Tor туннель
├── security.sh              # UFW, BBR, Fail2Ban, SSH
├── logs.sh                  # Логи, logrotate, cron
└── menu.sh                  # Главное меню

/usr/local/etc/xray/
├── config.json              # Конфиг VLESS+WS
├── reality.json             # Конфиг VLESS+Reality
├── reality_client.txt       # Параметры клиента Reality
├── warp_domains.txt         # Домены для WARP split
├── warp2_domains.txt        # Домены для WARP2 split
├── psiphon.json             # Конфиг Psiphon
├── psiphon_domains.txt      # Домены для Psiphon split
├── tor_domains.txt          # Домены для Tor split
├── relay.conf               # Конфиг Relay
├── relay_domains.txt        # Домены для Relay split
└── warp2-proxy.json         # Конфиг xray-warp2

/etc/systemd/system/
├── xray.service             # VLESS+WS
├── xray-reality.service     # Reality
├── xray-warp2.service       # WARP2 proxy
└── psiphon.service          # Psiphon

/etc/wireguard/
└── warp2.conf               # WireGuard конфиг WARP2

/etc/cron.d/
├── acme-renew               # Автообновление SSL
├── clear-logs               # Автоочистка логов
└── warp-watchdog            # Мониторинг WARP

/etc/sysctl.d/
└── 99-xray.conf             # Anti-ping, IPv6 off, somaxconn
```

## Решение проблем

### WARP не подключается
```bash
systemctl restart warp-svc
sleep 5
warp-cli --accept-tos connect
```

### Psiphon не подключается
```bash
# Переключить на режим "через WARP" — пункт 33 → 10
# Или проверить логи:
tail -50 /var/log/psiphon/psiphon.log
```

### WARP2 не поднимается
```bash
systemctl status wg-quick@warp2
journalctl -u wg-quick@warp2 -n 30
```

### Reality не запускается
```bash
systemctl status xray-reality
xray -test -config /usr/local/etc/xray/reality.json
```

### Nginx не запускается после отключения IPv6
```bash
sed -i '/listen \[::\]:443/d' /etc/nginx/conf.d/xray.conf
nginx -t && systemctl reload nginx
```

### SSL истёк
```bash
vwn  # Пункт 7 или пункт 28
```

## Удаление

```bash
vwn  # Пункт 26
```

Удаляет: Xray, Nginx, WARP, Psiphon, Tor, WARP2, все конфиги, сервисы, cron задачи, sysctl настройки.

## Зависимости

- [Xray-core](https://github.com/XTLS/Xray-core)
- [Cloudflare WARP](https://1.1.1.1/)
- [wgcf](https://github.com/ViRb3/wgcf) (для WARP2)
- [Psiphon tunnel core](https://github.com/Psiphon-Labs/psiphon-tunnel-core-binaries)
- [acme.sh](https://github.com/acmesh-official/acme.sh)
- nginx, jq, ufw, tor, wireguard-tools, proxychains4, qrencode

## Лицензия

MIT License
