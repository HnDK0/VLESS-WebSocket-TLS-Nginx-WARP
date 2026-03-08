<details open>
<summary>🇬🇧 English</summary>

# VWN — Xray Management Panel

Automated installer for Xray VLESS with WebSocket+TLS, Reality, Cloudflare WARP, CDN, Relay, Psiphon, and Tor support.

## Quick Install

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/HnDK0/VLESS-WebSocket-TLS-Nginx-WARP/main/install.sh)
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
- ✅ **CF Guard** — blocks direct access, only Cloudflare IPs allowed
- ✅ **Multi-user** — multiple UUIDs with labels, individual QR codes and subscription URLs
- ✅ **Subscription URL** — per-user `/sub/` link for v2rayNG, Hiddify, Nekoray and others
- ✅ **Backup & Restore** — manual backup/restore of all configs
- ✅ **Diagnostics** — full system check with per-component breakdown
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

## CLI Commands

```bash
vwn           # Open interactive menu
vwn update    # Update modules (no config changes)
```

## Menu

```
================================================================
   VWN — Xray Management Panel  07.03.2026 21:00
================================================================
  ── Protocols ──────────────────────────────────────────
  WS:      RUNNING,  WARP: ACTIVE | Split
  Reality: RUNNING,  SSL: OK (89d)
  Nginx:   RUNNING,  CF Guard: OFF
  CDN:     www.exemple.com
  ── Tunnels ────────────────────────────────────────────
  Relay: OFF,  Psiphon: OFF,  Tor: OFF
  ── Security ───────────────────────────────────────────
  BBR: ON,  F2B: ON,  Jail: PROTECTED
----------------------------------------------------------------
  1.  Install Xray (VLESS+WS+TLS+WARP+CDN)
  2.  Manage users

  ── Protocols ──────────────────────────────────────────
  3.  Manage WS + CDN
  4.  Manage VLESS + Reality

  ── Tunnels ────────────────────────────────────────────
  5.  Manage Relay (external)
  6.  Manage Psiphon
  7.  Manage Tor

  ── WARP ───────────────────────────────────────────────
  8.  Toggle WARP mode (Global/Split/OFF)
  9.  Add domain to WARP
  10. Remove domain from WARP
  11. Edit WARP list (Nano)
  12. Check IP (Real vs WARP)
  13. Install WARP Watchdog

  ── Security ───────────────────────────────────────────
  14. Enable BBR
  15. Enable Fail2Ban
  16. Enable Web-Jail
  17. Change SSH port
  18. Manage UFW

  ── Logs ───────────────────────────────────────────────
  19. Xray logs (access)
  20. Xray logs (error)
  21. Nginx logs (access)
  22. Nginx logs (error)
  23. Clear all logs

  ── Services ───────────────────────────────────────────
  24. Restart all services
  25. Update Xray-core
  26. Diagnostics
  27. Backup & Restore
  28. Change language
  29. Full removal

  ── Exit ───────────────────────────────────────────────
  0.  Exit
```

### Status indicators

| Status | Meaning |
|--------|---------|
| `ACTIVE \| Global` | All traffic routed through tunnel |
| `ACTIVE \| Split` | Only domains from the list |
| `ACTIVE \| route OFF` | Service running but not in routing |
| `OFF` | Service not running |

## Multi-user (item 2)

Multiple VLESS UUIDs with labels (e.g. "iPhone Vasya", "Laptop work").

- Each user gets their own UUID applied to both WS and Reality configs instantly
- Add / Remove / Rename users
- Individual QR code per user (WS and Reality links)
- Individual subscription URL per user
- Cannot delete the last user
- Users stored in `/usr/local/etc/xray/users.conf` (format: `UUID|label|token`)

On first open, the existing UUID is automatically imported as user `default`.

## Subscription URL

Each user gets a personal subscription URL:

```
https://your-domain.com/sub/label_token.txt
```

The file is base64-encoded and contains all connection links for that user (WS+TLS and Reality if installed). Compatible with v2rayNG, Hiddify, Nekoray, Mihomo/Clash Meta and others.

- URL does not change when configs are updated — only the content changes
- URL changes only when the user is renamed
- Manage via item 2 → item 3 (QR + Subscription URL) or item 5 (Rebuild all)

## WS + CDN Management (item 3)

Submenu for managing the WebSocket+TLS setup:

| Item | Action |
|------|--------|
| 1 | Change Xray port |
| 2 | Change WS path |
| 3 | Change domain |
| 4 | Connection address (CDN domain) |
| 5 | Reissue SSL certificate |
| 6 | Change stub site |
| 7 | CF Guard — Cloudflare-only access (block direct) |
| 8 | Update Cloudflare IPs |
| 9 | Manage SSL auto-renewal |
| 10 | Manage log auto-clear |
| 11 | Change UUID |

## Backup & Restore (item 27)

Backups stored in `/root/vwn-backups/` with timestamps. No auto-deletion.

What is backed up: Xray configs, Nginx + SSL certs, Cloudflare API key, cron tasks, Fail2Ban rules.

## Diagnostics (item 26)

Full scan or per-component check via submenu:

| Section | Checks |
|---------|--------|
| System | RAM, disk, swap, clock sync |
| Xray | Config validity, service status, ports |
| Nginx | Config, service, port 443, SSL expiry, DNS |
| WARP | warp-svc, connection, SOCKS5 response |
| Tunnels | Psiphon / Tor / Relay status |
| Connectivity | Internet, domain reachability |

Output: `✓` / `✗` per check, summary of issues at the end.

## SSL Certificates

**Method 1 — Cloudflare DNS API** (recommended): port 80 not needed.  
**Method 2 — Standalone**: temporarily opens port 80.

Auto-renewal via cron every 35 days at 03:00.

## CF Guard (item 3 → 7)

Blocks direct server access — only requests coming through Cloudflare IPs are allowed. Enable after setting up the orange cloud in Cloudflare DNS. Use item 3 → 8 to refresh the Cloudflare IP list.

Note: Real IP restoration (`CF-Connecting-IP`) is applied automatically on installation and is independent of CF Guard.

## File Structure

```
/usr/local/lib/vwn/
├── lang.sh       # Localisation (RU/EN)
├── core.sh       # Variables, utilities, status
├── xray.sh       # Xray WS+TLS config
├── nginx.sh      # Nginx, CDN, SSL, subscriptions
├── warp.sh       # WARP management
├── reality.sh    # VLESS+Reality
├── relay.sh      # External outbound
├── psiphon.sh    # Psiphon tunnel
├── tor.sh        # Tor tunnel
├── security.sh   # UFW, BBR, Fail2Ban, SSH
├── logs.sh       # Logs, logrotate, cron
├── backup.sh     # Backup & Restore
├── users.sh      # Multi-user management
├── diag.sh       # Diagnostics
└── menu.sh       # Main menu

/usr/local/etc/xray/
├── config.json              # VLESS+WS config
├── reality.json             # VLESS+Reality config
├── reality_client.txt       # Reality client params
├── vwn.conf                 # VWN settings (lang, etc.)
├── users.conf               # User list (UUID|label|token)
├── sub/                     # Subscription files
│   └── label_token.txt
├── warp_domains.txt
├── psiphon.json
├── psiphon_domains.txt
├── tor_domains.txt
├── relay.conf
└── relay_domains.txt

/root/vwn-backups/
└── vwn-backup-YYYY-MM-DD_HH-MM-SS.tar.gz
```

## Troubleshooting

```bash
# Something not working — run diagnostics
vwn  # item 26

# WARP won't connect
systemctl restart warp-svc && sleep 5 && warp-cli --accept-tos connect

# Psiphon logs
tail -50 /var/log/psiphon/psiphon.log

# Reality won't start
xray -test -config /usr/local/etc/xray/reality.json

# Nginx after IPv6 disable
sed -i '/listen \[::\]:443/d' /etc/nginx/conf.d/xray.conf && nginx -t && systemctl reload nginx

# Tor — try bridges (item 7 → 11)
tail -50 /var/log/tor/notices.log

# Subscription not updating
vwn  # item 2 → item 5 (Rebuild all subscription files)
```

## Removal

```bash
vwn  # item 29
```

Note: backups in `/root/vwn-backups/` are not removed automatically.

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

<details>
<summary>🇷🇺 Русский</summary>

# VWN — Xray Management Panel

Автоматический установщик Xray VLESS с поддержкой WebSocket+TLS, Reality, Cloudflare WARP, CDN, Relay, Psiphon и Tor.

## Быстрая установка

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/HnDK0/VLESS-WebSocket-TLS-Nginx-WARP/main/install.sh)
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
- ✅ **CF Guard** — блокировка прямого доступа, только Cloudflare IP
- ✅ **Мульти-пользователи** — несколько UUID с метками, индивидуальные QR коды и ссылки подписки
- ✅ **Ссылка подписки** — персональный `/sub/` URL для v2rayNG, Hiddify, Nekoray и других
- ✅ **Бэкап и восстановление** — ручной бэкап/восстановление всех конфигов
- ✅ **Диагностика** — полная проверка системы с детализацией по компонентам
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

## CLI команды

```bash
vwn           # Открыть интерактивное меню
vwn update    # Обновить модули (без изменения конфигов)
```

## Меню управления

```
================================================================
   VWN — Xray Management Panel  07.03.2026 21:00
================================================================
  ── Протоколы ──────────────────────────────────────────
  WS:      RUNNING,  WARP: ACTIVE | Split
  Reality: RUNNING,  SSL: OK (89d)
  Nginx:   RUNNING,  CF Guard: OFF
  CDN:     www.exemple.com
  ── Туннели ────────────────────────────────────────────
  Relay: OFF,  Psiphon: OFF,  Tor: OFF
  ── Безопасность ───────────────────────────────────────
  BBR: ON,  F2B: ON,  Jail: PROTECTED
----------------------------------------------------------------
  1.  Установить Xray (VLESS+WS+TLS+WARP+CDN)
  2.  Управление пользователями

  ── Протоколы ──────────────────────────────────────────
  3.  Управление WS + CDN
  4.  Управление VLESS + Reality

  ── Туннели ────────────────────────────────────────────
  5.  Управление Relay (внешний сервер)
  6.  Управление Psiphon
  7.  Управление Tor

  ── WARP ───────────────────────────────────────────────
  8.  Переключить режим WARP (Global/Split/OFF)
  9.  Добавить домен в WARP
  10. Удалить домен из WARP
  11. Редактировать список WARP (Nano)
  12. Проверить IP (Real vs WARP)
  13. Установить WARP Watchdog

  ── Безопасность ───────────────────────────────────────
  14. Включить BBR
  15. Включить Fail2Ban
  16. Включить Web-Jail
  17. Сменить SSH порт
  18. Управление UFW

  ── Логи ───────────────────────────────────────────────
  19. Логи Xray (access)
  20. Логи Xray (error)
  21. Логи Nginx (access)
  22. Логи Nginx (error)
  23. Очистить все логи

  ── Сервисы ────────────────────────────────────────────
  24. Перезапустить все сервисы
  25. Обновить Xray-core
  26. Диагностика
  27. Бэкап и восстановление
  28. Сменить язык / Change language
  29. Полное удаление

  ── Выход ──────────────────────────────────────────────
  0.  Выйти
```

### Статусы в заголовке

| Статус | Описание |
|--------|----------|
| `ACTIVE \| Global` | Весь трафик идёт через туннель |
| `ACTIVE \| Split` | Только домены из списка |
| `ACTIVE \| маршрут OFF` | Сервис запущен, но не в роутинге |
| `OFF` | Сервис не запущен |

## Мульти-пользователи (пункт 2)

Несколько VLESS UUID с произвольными метками ("iPhone Vasya", "Ноутбук работа").

- Добавить / Удалить / Переименовать / QR для каждого
- Изменения мгновенно применяются к обоим конфигам (WS и Reality)
- Индивидуальная ссылка подписки для каждого пользователя
- Последнего пользователя удалить нельзя
- Хранится в `/usr/local/etc/xray/users.conf` (формат: `UUID|метка|токен`)

При первом открытии существующий UUID импортируется как пользователь `default`.

## Ссылка подписки

Каждый пользователь получает персональную ссылку подписки:

```
https://ваш-домен.com/sub/label_token.txt
```

Файл закодирован в base64 и содержит все ссылки подключения для этого пользователя (WS+TLS и Reality если установлен). Совместим с v2rayNG, Hiddify, Nekoray, Mihomo/Clash Meta и другими.

- URL не меняется при обновлении конфигов — меняется только содержимое
- URL меняется только при переименовании пользователя
- Управление через пункт 2 → пункт 3 (QR + Subscription URL) или пункт 5 (Пересоздать все)

## Управление WS + CDN (пункт 3)

Подменю управления WebSocket+TLS установкой:

| Пункт | Действие |
|-------|----------|
| 1 | Изменить порт Xray |
| 2 | Изменить путь WS |
| 3 | Сменить домен |
| 4 | Адрес подключения (CDN домен) |
| 5 | Перевыпустить SSL сертификат |
| 6 | Изменить сайт-заглушку |
| 7 | CF Guard — только Cloudflare IP (блок прямого доступа) |
| 8 | Обновить IP Cloudflare |
| 9 | Управление автообновлением SSL |
| 10 | Управление автоочисткой логов |
| 11 | Сменить UUID |

## Бэкап и восстановление (пункт 27)

Бэкапы в `/root/vwn-backups/` с датой и временем. Автоудаления нет.

Включает: конфиги Xray, Nginx + SSL, API ключи Cloudflare, cron, Fail2Ban.

## Диагностика (пункт 26)

| Раздел | Проверки |
|--------|----------|
| Система | RAM, диск, swap, часы |
| Xray | Конфиги, сервисы, порты |
| Nginx | Конфиг, сервис, SSL, DNS |
| WARP | warp-svc, подключение, SOCKS5 |
| Туннели | Psiphon / Tor / Relay |
| Связность | Интернет, домен |

Вывод: `✓` / `✗` по каждой проверке + итоговый список проблем.

## Туннели (пункты 3–7)

Все туннели поддерживают режимы: **Global / Split / OFF**. Применяются к обоим конфигам (WS и Reality).

### VLESS + Reality (пункт 4)

Прямые подключения без CDN. Отдельный сервис `xray-reality`.

```
vless://UUID@IP:8443?security=reality&sni=microsoft.com&fp=chrome&pbk=KEY&sid=SID&type=tcp&flow=xtls-rprx-vision
```

### Relay (пункт 5)

Поддерживает: `vless://` `vmess://` `trojan://` `socks5://`

### Psiphon (пункт 6)

Выбор страны выхода: DE, NL, US, GB, FR, AT, CA, SE и др.

### Tor (пункт 7)

Выбор страны выхода через `ExitNodes`. Поддержка мостов: obfs4, snowflake, meek-azure. **Рекомендуется Split режим** — Tor медленнее обычного интернета.

## WARP (пункты 8–13)

**Split** (по умолчанию): `openai.com, chatgpt.com, oaistatic.com, oaiusercontent.com, auth0.openai.com`

**Global** — весь трафик через WARP. **OFF** — отключён от роутинга.

**WARP Watchdog (пункт 13)** — cron каждые 2 минуты, автопереподключение.

## SSL сертификаты

**Метод 1 — Cloudflare DNS API** (рекомендуется): порт 80 не нужен.  
**Метод 2 — Standalone**: временно открывает порт 80.

Автообновление через cron раз в 35 дней в 3:00.

## CF Guard (пункт 3 → 7)

Блокирует прямой доступ к серверу — пропускает только запросы с IP Cloudflare. Включайте после настройки оранжевого облака в Cloudflare DNS. Пункт 3 → 8 — обновить список IP Cloudflare вручную.

Примечание: восстановление реального IP (`CF-Connecting-IP`) применяется автоматически при установке и не зависит от CF Guard.

## Структура файлов

```
/usr/local/lib/vwn/
├── lang.sh       # Локализация (RU/EN)
├── core.sh       # Переменные, утилиты, статусы
├── xray.sh       # Xray WS+TLS конфиг
├── nginx.sh      # Nginx, CDN, SSL, подписки
├── warp.sh       # WARP управление
├── reality.sh    # VLESS+Reality
├── relay.sh      # Внешний outbound
├── psiphon.sh    # Psiphon туннель
├── tor.sh        # Tor туннель
├── security.sh   # UFW, BBR, Fail2Ban, SSH
├── logs.sh       # Логи, logrotate, cron
├── backup.sh     # Бэкап и восстановление
├── users.sh      # Управление пользователями
├── diag.sh       # Диагностика
└── menu.sh       # Главное меню

/usr/local/etc/xray/
├── config.json              # Конфиг VLESS+WS
├── reality.json             # Конфиг VLESS+Reality
├── reality_client.txt       # Параметры клиента Reality
├── vwn.conf                 # Настройки VWN (язык и др.)
├── users.conf               # Список пользователей (UUID|метка|токен)
├── sub/                     # Файлы подписок
│   └── label_token.txt
├── warp_domains.txt
├── psiphon.json
├── psiphon_domains.txt
├── tor_domains.txt
├── relay.conf
└── relay_domains.txt

/root/vwn-backups/
└── vwn-backup-YYYY-MM-DD_HH-MM-SS.tar.gz
```

## Решение проблем

```bash
# Что-то не работает — запустить диагностику
vwn  # пункт 26

# WARP не подключается
systemctl restart warp-svc && sleep 5 && warp-cli --accept-tos connect

# Логи Psiphon
tail -50 /var/log/psiphon/psiphon.log

# Reality не запускается
xray -test -config /usr/local/etc/xray/reality.json

# Nginx после отключения IPv6
sed -i '/listen \[::\]:443/d' /etc/nginx/conf.d/xray.conf && nginx -t && systemctl reload nginx

# Tor — попробовать мосты (пункт 7 → 11)
tail -50 /var/log/tor/notices.log

# Подписка не обновляется
vwn  # пункт 2 → пункт 5 (Пересоздать файлы подписки)
```

## Удаление

```bash
vwn  # Пункт 29
```

Бэкапы в `/root/vwn-backups/` автоматически не удаляются.

## Зависимости

- [Xray-core](https://github.com/XTLS/Xray-core)
- [Cloudflare WARP](https://1.1.1.1/)
- [Psiphon tunnel core](https://github.com/Psiphon-Labs/psiphon-tunnel-core-binaries)
- [acme.sh](https://github.com/acmesh-official/acme.sh)
- nginx, jq, ufw, tor, obfs4proxy, qrencode

## Лицензия

MIT License

</details>