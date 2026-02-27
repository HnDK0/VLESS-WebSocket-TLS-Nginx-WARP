<details open>
<summary>🇬🇧 English</summary>

# VWN — Xray VLESS + WARP + CDN + Reality

Automated installer for Xray VLESS with WebSocket+TLS, Reality, Cloudflare WARP, CDN, Relay, Psiphon, and Tor support.

## Quick Install

```bash
curl -L https://raw.githubusercontent.com/HnDK0/VLESS-WebSocket-TLS-Nginx-WARP/main/install.sh -o vwn && bash vwn
```

After installation the script is available as a command:
```bash
vwn
```

Update modules (without touching configs):
```bash
vwn update
```

## Requirements

- Ubuntu 22.04+ / Debian 11+
- Root access
- A domain pointed at the server (for WS+TLS)
- For Reality — only the server IP is needed, no domain required

## Features

- ✅ **VLESS + WebSocket + TLS** — connections via Cloudflare CDN
- ✅ **VLESS + Reality** — direct connections without CDN (router, Clash)
- ✅ **Nginx** — reverse proxy with a stub/decoy site
- ✅ **Cloudflare WARP** — route selected domains or all traffic
- ✅ **Psiphon** — censorship bypass with exit country selection
- ✅ **Tor** — censorship bypass with exit country selection, bridge support (obfs4, snowflake, meek)
- ✅ **Relay** — external outbound (VLESS/VMess/Trojan/SOCKS via link)
- ✅ **CDN protection** — blocks direct access, only via Cloudflare
- ✅ **WARP Watchdog** — auto-reconnect WARP on failure
- ✅ **Fail2Ban + Web-Jail** — brute-force and scanner protection
- ✅ **BBR** — TCP acceleration
- ✅ **Anti-Ping** — ICMP disabled
- ✅ **IPv6 disabled system-wide** — forced IPv4
- ✅ **Privacy** — access logs off, sniffing disabled
- ✅ **RU / EN interface** — language selector on first run

## Architecture

```
Client (CDN/mobile)
    └── Cloudflare CDN → 443/HTTPS → Nginx → VLESS+WS → Xray → outbound

Client (router/Clash/direct)
    └── IP:8443/TCP → VLESS+Reality → Xray → outbound

outbound (by routing rules):
    ├── free    — direct exit (default)
    ├── warp    — Cloudflare WARP (SOCKS5:40000)
    ├── psiphon — Psiphon tunnel (SOCKS5:40002)
    ├── tor     — Tor (SOCKS5:40003)
    ├── relay   — external server (vless/vmess/trojan/socks)
    └── block   — blackhole (geoip:private)
```

## Ports

| Port  | Purpose                           |
|-------|-----------------------------------|
| 22    | SSH (configurable)                |
| 443   | VLESS+WS+TLS via Nginx            |
| 8443  | VLESS+Reality (default)           |
| 40000 | WARP SOCKS5 (warp-cli, local)     |
| 40002 | Psiphon SOCKS5 (local)            |
| 40003 | Tor SOCKS5 (local)                |
| 40004 | Tor Control Port (local)          |

## Menu

```
================================================================
   XRAY VLESS + WARP + CDN + REALITY | 27.02.2026 21:00
================================================================
  NGINX: RUNNING  |  XRAY: RUNNING  |  WARP: ACTIVE | Split
  SSL: OK (89 d)  |  BBR: ON  |  F2B: OFF
  WebJail: NO  |  CDN: OFF  |  Reality: ON (port 8443)
  Relay: ON | Split  |  Psiphon: ON | Split, DE  |  Tor: ON | Split, US
----------------------------------------------------------------
    1.  Install Xray (VLESS+WS+TLS+WARP+CDN)
    2.  Show QR code and link
    3.  Change UUID
    ─── Configuration ───────────────────
    4.  Change Xray port
    5.  Change WebSocket path
    6.  Change stub site
    7.  Reissue SSL certificate
    8.  Change domain
    ─── CDN & WARP ──────────────────────
    9.  Toggle CDN mode (ON/OFF)
    10. Toggle WARP mode (Global/Split/OFF)
    11. Add domain to WARP
    12. Remove domain from WARP
    13. Edit WARP list (Nano)
    14. Check IP (Real vs WARP)
    ─── Security ────────────────────────
    15. Enable BBR
    16. Enable Fail2Ban
    17. Enable Web-Jail
    18. Change SSH port
    30. Install WARP Watchdog
    ─── Logs ────────────────────────────
    19. Xray logs (access)
    20. Xray logs (error)
    21. Nginx logs (access)
    22. Nginx logs (error)
    23. Clear all logs
    ─── Services ────────────────────────
    24. Restart all services
    25. Update Xray-core
    26. Full removal
    ─── UFW, SSL, Logs ──────────────────
    27. Manage UFW
    28. Manage SSL auto-renewal
    29. Manage log auto-clear
    ─── Tunnels ─────────────────────────
    31. Manage VLESS + Reality
    32. Manage Relay (external)
    33. Manage Psiphon
    34. Manage Tor
    35. Change language / Сменить язык
    ─── Exit ────────────────────────────
    0.  Exit
----------------------------------------------------------------
```

### Status indicators

Each tunnel shows its current routing mode in the header:

| Status | Meaning |
|--------|---------|
| `ACTIVE \| Global` | All traffic routed through tunnel |
| `ACTIVE \| Split` | Only domains from the list |
| `ACTIVE \| route OFF` | Service running but not in routing |
| `OFF` | Service not running |

## Tunnels (items 31–34)

All tunnels work the same way:
- **Global** — all traffic through the tunnel
- **Split** — only domains from the list
- **OFF** — removed from Xray routing (service stays running)
- Applied simultaneously to both configs (WS and Reality)

### VLESS + Reality (item 31)

Direct connections without CDN. Runs as a separate `xray-reality` service.

```
vless://UUID@IP:8443?security=reality&sni=microsoft.com&fp=chrome&pbk=KEY&sid=SID&type=tcp&flow=xtls-rprx-vision
```

### Relay — external server (item 32)

Route traffic through an external server. Supports link formats:
```
vless://...  vmess://...  trojan://...  socks5://...
```

Modes: **Global / Split / OFF**. Switch via item 2 in submenu.

### Psiphon (item 33)

Censorship bypass with exit country selection (DE, NL, US, GB, FR, AT, CA, SE, etc.).

Modes: **Global / Split / OFF**. Switch via item 2 in submenu.

### Tor (item 34)

Censorship bypass with exit country via `ExitNodes`.

Modes: **Global / Split / OFF**. Switch via item 2 in submenu.

**Additional:**
- **Renew circuit** — request new IP without restarting Tor
- **Bridges** — obfs4, snowflake, meek-azure support for bypassing Tor blocks
- IP check with exit country detection

**Tip:** Use Split mode — Tor is slower than regular internet.

## WARP (items 10–14)

**Split mode** (default) — only selected domains via WARP:
```
openai.com, chatgpt.com, oaistatic.com, oaiusercontent.com, auth0.openai.com
```

**Global mode** — all traffic via WARP.

**OFF** — WARP removed from Xray routing.

**WARP Watchdog (item 30)** — cron every 2 minutes, auto-reconnect on failure.

## SSL Certificates

**Method 1 — Cloudflare DNS API** (recommended): port 80 not needed, requires Email and Global API Key.

**Method 2 — Standalone**: temporarily opens port 80, no API keys needed.

Auto-renewal via `/etc/cron.d/acme-renew` — every 35 days at 03:00.

## CDN Mode (item 9)

Downloads current Cloudflare IPs, blocks direct server access (`return 444`), only Cloudflare Proxy allowed. Enable only after setting up domain with orange cloud in Cloudflare.

## File Structure

```
/usr/local/lib/vwn/          # Modules
├── lang.sh                  # Localisation (RU/EN)
├── core.sh                  # Variables, utilities, status
├── xray.sh                  # Xray WS+TLS config
├── nginx.sh                 # Nginx, CDN, SSL
├── warp.sh                  # WARP management
├── reality.sh               # VLESS+Reality
├── relay.sh                 # External outbound
├── psiphon.sh               # Psiphon tunnel
├── tor.sh                   # Tor tunnel
├── security.sh              # UFW, BBR, Fail2Ban, SSH
├── logs.sh                  # Logs, logrotate, cron
└── menu.sh                  # Main menu

/usr/local/etc/xray/
├── config.json              # VLESS+WS config
├── reality.json             # VLESS+Reality config
├── reality_client.txt       # Reality client params
├── vwn.conf                 # VWN settings (language etc.)
├── warp_domains.txt         # WARP split domains
├── psiphon.json             # Psiphon config
├── psiphon_domains.txt      # Psiphon split domains
├── tor_domains.txt          # Tor split domains
├── relay.conf               # Relay config
└── relay_domains.txt        # Relay split domains

/etc/systemd/system/
├── xray.service             # VLESS+WS
├── xray-reality.service     # Reality
└── psiphon.service          # Psiphon

/etc/cron.d/
├── acme-renew               # SSL auto-renewal
├── clear-logs               # Log auto-clear
└── warp-watchdog            # WARP monitoring

/etc/sysctl.d/
└── 99-xray.conf             # Anti-ping, IPv6 off, somaxconn
```

## Troubleshooting

### WARP won't connect
```bash
systemctl restart warp-svc
sleep 5
warp-cli --accept-tos connect
```

### Psiphon won't connect
```bash
tail -50 /var/log/psiphon/psiphon.log
```

### Reality won't start
```bash
systemctl status xray-reality
xray -test -config /usr/local/etc/xray/reality.json
```

### Nginx won't start after IPv6 disable
```bash
sed -i '/listen \[::\]:443/d' /etc/nginx/conf.d/xray.conf
nginx -t && systemctl reload nginx
```

### SSL expired
```bash
vwn  # Item 7 or item 28
```

### Tor won't connect
```bash
# Try bridges (item 34 → 11)
systemctl status tor
tail -50 /var/log/tor/notices.log
```

## Removal

```bash
vwn  # Item 26
```

Removes: Xray, Nginx, WARP, Psiphon, Tor, all configs, services, cron tasks, sysctl settings.

## Dependencies

- [Xray-core](https://github.com/XTLS/Xray-core)
- [Cloudflare WARP](https://1.1.1.1/)
- [Psiphon tunnel core](https://github.com/Psiphon-Labs/psiphon-tunnel-core-binaries)
- [acme.sh](https://github.com/acmesh-official/acme.sh)
- nginx, jq, ufw, tor, obfs4proxy, qrencode

## License

MIT License

</details>

---

<details open>
<summary>🇷🇺 Русский</summary>

# VWN — Xray VLESS + WARP + CDN + Reality

Автоматический установщик Xray VLESS с поддержкой WebSocket+TLS, Reality, Cloudflare WARP, CDN, Relay, Psiphon и Tor.

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
- ✅ **Psiphon** — обход блокировок с выбором страны выхода
- ✅ **Tor** — обход блокировок с выбором страны выхода, поддержка мостов (obfs4, snowflake, meek)
- ✅ **Relay** — внешний outbound (VLESS/VMess/Trojan/SOCKS по ссылке)
- ✅ **CDN защита** — блокировка прямого доступа, только через Cloudflare
- ✅ **WARP Watchdog** — автовосстановление WARP при обрыве
- ✅ **Fail2Ban + Web-Jail** — защита от брутфорса и сканеров
- ✅ **BBR** — ускорение TCP
- ✅ **Anti-Ping** — отключение ICMP
- ✅ **IPv6 отключён системно** — принудительный IPv4
- ✅ **Приватность** — access логи отключены, sniffing выключен
- ✅ **RU / EN интерфейс** — выбор языка при первом запуске

## Архитектура

```
Клиент (CDN/мобильный)
    └── Cloudflare CDN → 443/HTTPS → Nginx → VLESS+WS → Xray → outbound

Клиент (роутер/Clash/прямое)
    └── IP:8443/TCP → VLESS+Reality → Xray → outbound

outbound (по routing rules):
    ├── free    — прямой выход (default)
    ├── warp    — Cloudflare WARP (SOCKS5:40000)
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
| 40002 | Psiphon SOCKS5 (локальный)        |
| 40003 | Tor SOCKS5 (локальный)            |
| 40004 | Tor Control Port (локальный)      |

## Меню управления

```
================================================================
   XRAY VLESS + WARP + CDN + REALITY | 27.02.2026 21:00
================================================================
  NGINX: RUNNING  |  XRAY: RUNNING  |  WARP: ACTIVE | Split
  SSL: OK (89 d)  |  BBR: ON  |  F2B: OFF
  WebJail: NO  |  CDN: OFF  |  Reality: ON (порт 8443)
  Relay: ON | Split  |  Psiphon: ON | Split, DE  |  Tor: ON | Split, US
----------------------------------------------------------------
    1.  Установить Xray (VLESS+WS+TLS+WARP+CDN)
    2.  Показать QR-код и ссылку
    3.  Сменить UUID
    ─────────────── Конфигурация ─────────────
    4.  Изменить порт Xray
    5.  Изменить путь WebSocket
    6.  Изменить сайт-заглушку
    7.  Перевыпустить SSL сертификат
    8.  Сменить домен
    ─────────────── CDN и WARP ───────────────
    9.  Переключить CDN режим (ON/OFF)
    10. Переключить режим WARP (Global/Split/OFF)
    11. Добавить домен в WARP
    12. Удалить домен из WARP
    13. Редактировать список WARP (Nano)
    14. Проверить IP (Real vs WARP)
    ─────────────── Безопасность ─────────────
    15. Включить BBR
    16. Включить Fail2Ban
    17. Включить Web-Jail
    18. Сменить SSH порт
    30. Установить WARP Watchdog
    ─────────────── Логи ─────────────────────
    19. Логи Xray (access)
    20. Логи Xray (error)
    21. Логи Nginx (access)
    22. Логи Nginx (error)
    23. Очистить все логи
    ─────────────── Сервисы ──────────────────
    24. Перезапустить все сервисы
    25. Обновить Xray-core
    26. Полное удаление
    ─────────────── UFW, SSL, Logs ───────────
    27. Управление UFW
    28. Управление автообновлением SSL
    29. Управление автоочисткой логов
    ─────────────── Туннели ──────────────────
    31. Управление VLESS + Reality
    32. Управление Relay (внешний сервер)
    33. Управление Psiphon
    34. Управление Tor
    35. Сменить язык / Change language
    ─────────────── Выход ────────────────────
    0.  Выйти
----------------------------------------------------------------
```

### Статусы в заголовке

Каждый туннель показывает текущий режим маршрутизации прямо в шапке:

| Статус | Описание |
|--------|----------|
| `ACTIVE \| Global` | Весь трафик идёт через туннель |
| `ACTIVE \| Split` | Только домены из списка |
| `ACTIVE \| маршрут OFF` | Сервис запущен, но не в роутинге |
| `OFF` | Сервис не запущен |

## Туннели (пункты 31–34)

Все туннели работают по одинаковой схеме:
- **Global** — весь трафик через туннель
- **Split** — только домены из списка
- **OFF** — туннель отключён от роутинга Xray (сервис остаётся запущенным)
- Применяются одновременно к обоим конфигам (WS и Reality)

### VLESS + Reality (пункт 31)

Прямые подключения без CDN. Работает как отдельный сервис `xray-reality`.

```
vless://UUID@IP:8443?security=reality&sni=microsoft.com&fp=chrome&pbk=KEY&sid=SID&type=tcp&flow=xtls-rprx-vision
```

### Relay — внешний сервер (пункт 32)

Перенаправление трафика через внешний сервер. Поддерживает ссылки:
```
vless://...  vmess://...  trojan://...  socks5://...
```

Режимы: **Global / Split / OFF**. Переключение — пункт 2 в подменю.

### Psiphon (пункт 33)

Обход блокировок с выбором страны выхода (DE, NL, US, GB, FR, AT, CA, SE и др.).

Режимы: **Global / Split / OFF**. Переключение — пункт 2 в подменю.

### Tor (пункт 34)

Обход блокировок с выбором страны выхода через `ExitNodes`.

Режимы: **Global / Split / OFF**. Переключение — пункт 2 в подменю.

**Дополнительно:**
- **Обновить цепь** — запросить новый IP без перезапуска Tor
- **Мосты (Bridges)** — obfs4, snowflake, meek-azure для обхода блокировки самого Tor
- Проверка IP с определением страны выхода

**Рекомендация:** использовать Split режим — Tor медленнее обычного интернета.

## WARP (пункты 10–14)

**Split режим** (по умолчанию) — только выбранные домены через WARP:
```
openai.com, chatgpt.com, oaistatic.com, oaiusercontent.com, auth0.openai.com
```

**Global режим** — весь трафик через WARP.

**OFF** — WARP отключён от роутинга Xray.

**WARP Watchdog (пункт 30)** — cron каждые 2 минуты, автопереподключение при обрыве.

## SSL сертификаты

**Метод 1 — Cloudflare DNS API** (рекомендуется): порт 80 не нужен, требуются Email и Global API Key.

**Метод 2 — Standalone**: временно открывает порт 80, API ключи не нужны.

Автообновление через `/etc/cron.d/acme-renew` — раз в 35 дней в 3:00.

## CDN режим (пункт 9)

При включении скачиваются актуальные IP Cloudflare, прямой доступ блокируется (`return 444`), доступ только через Cloudflare Proxy. Включайте только после настройки домена с оранжевым облаком.

## Структура файлов

```
/usr/local/lib/vwn/          # Модули
├── lang.sh                  # Локализация (RU/EN)
├── core.sh                  # Переменные, утилиты, статусы
├── xray.sh                  # Xray WS+TLS конфиг
├── nginx.sh                 # Nginx, CDN, SSL
├── warp.sh                  # WARP управление
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
├── vwn.conf                 # Настройки VWN (язык и др.)
├── warp_domains.txt         # Домены для WARP split
├── psiphon.json             # Конфиг Psiphon
├── psiphon_domains.txt      # Домены для Psiphon split
├── tor_domains.txt          # Домены для Tor split
├── relay.conf               # Конфиг Relay
└── relay_domains.txt        # Домены для Relay split

/etc/systemd/system/
├── xray.service             # VLESS+WS
├── xray-reality.service     # Reality
└── psiphon.service          # Psiphon

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
tail -50 /var/log/psiphon/psiphon.log
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

### Tor не подключается
```bash
# Попробовать мосты (пункт 34 → 11)
systemctl status tor
tail -50 /var/log/tor/notices.log
```

## Удаление

```bash
vwn  # Пункт 26
```

Удаляет: Xray, Nginx, WARP, Psiphon, Tor, все конфиги, сервисы, cron задачи, sysctl настройки.

## Зависимости

- [Xray-core](https://github.com/XTLS/Xray-core)
- [Cloudflare WARP](https://1.1.1.1/)
- [Psiphon tunnel core](https://github.com/Psiphon-Labs/psiphon-tunnel-core-binaries)
- [acme.sh](https://github.com/acmesh-official/acme.sh)
- nginx, jq, ufw, tor, obfs4proxy, qrencode

## Лицензия

MIT License

</details>
