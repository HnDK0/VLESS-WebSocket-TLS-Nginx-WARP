# Xray VLESS + WebSocket + TLS + Nginx + WARP + CDN + Reality

Автоматический установщик Xray VLESS с поддержкой WebSocket, TLS, Nginx, Cloudflare WARP, CDN защитой и VLESS+Reality для прямых подключений.

## Особенности

- ✅ **VLESS + WebSocket + TLS** — для подключений через Cloudflare CDN
- ✅ **VLESS + Reality** — для прямых подключений (роутер, Clash и др.)
- ✅ **Nginx** — reverse proxy с сайтом-заглушкой
- ✅ **Cloudflare WARP** — роутинг выбранных доменов (OpenAI, ChatGPT и др.)
- ✅ **WARP Watchdog** — автовосстановление WARP при обрыве
- ✅ **CDN поддержка** — блокировка прямого доступа, только через Cloudflare
- ✅ **Два метода SSL** — Cloudflare DNS API или Standalone
- ✅ **Fail2Ban + Web-Jail** — защита от брутфорса и сканеров
- ✅ **BBR** — ускорение TCP
- ✅ **Anti-Ping** — отключение ICMP для IPv4 и IPv6
- ✅ **IPv6 отключён системно** — принудительный IPv4 для всего трафика
- ✅ **Приватность** — access логи отключены, sniffing выключен
- ✅ **UseIPv4 outbound** — стабильная работа на хостингах с проблемным IPv6

## Быстрая установка

```bash
curl -L https://raw.githubusercontent.com/HnDK0/VLESS-WebSocket-TLS-Nginx-WARP/main/vless-setup.sh -o vwn && bash vwn
```

После первого запуска скрипт доступен как команда:
```bash
vwn
```

## Требования

- Ubuntu 22.04+ / Debian 11+
- Root доступ
- Домен, направленный на сервер (для WS+TLS)
- Для Reality — только IP сервера, домен не нужен

## Архитектура

```
Клиент (CDN/мобильный)
    └── Cloudflare CDN → 443/HTTPS → Nginx → VLESS+WS → Xray → WARP/Internet

Клиент (роутер/Clash/прямое)
    └── IP:8443/TCP → VLESS+Reality → Xray → WARP/Internet
```

## Порты

| Порт  | Назначение                  |
|-------|-----------------------------|
| 22    | SSH (изменяемый)            |
| 443   | VLESS+WS+TLS через Nginx    |
| 8443  | VLESS+Reality (по умолчанию)|
| 40000 | WARP SOCKS5 (локальный)     |

## Меню управления

```
================================================================
   XRAY VLESS + WARP + CDN + REALITY | 27.02.2026 21:00
================================================================
  NGINX: RUNNING  |  XRAY: RUNNING  |  WARP: ACTIVE
  SSL: OK (89 d)  |  BBR: ON  |  F2B: OFF
  WebJail: NO  |  CDN: OFF  |  Reality: ON (порт 8443)
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
    —————————————— Reality ——————————————————
    31. Управление VLESS + Reality
    —————————————— Выход ————————————————————
    0.  Выйти
----------------------------------------------------------------
```

## VLESS + Reality (пункт 31)

Reality — альтернативный транспорт для прямых подключений без CDN. Работает как отдельный сервис (`xray-reality`) параллельно с основным Xray.

**Когда использовать:**
- Clash на роутере (все устройства через роутер)
- Прямое подключение без Cloudflare
- Слабое железо роутера (меньше оверхед чем WS+TLS)

**Как работает:**
Xray маскируется под реальный сайт (например `microsoft.com`). Клиент подключается напрямую к IP сервера, TLS fingerprint выглядит как легитимный трафик. Сертификат не нужен.

**Подменю Reality:**
- Установить с выбором порта и dest-сайта (microsoft / apple / amazon / свой)
- Показать QR-код и ссылку для клиента
- Сменить UUID / порт / dest
- Логи / Перезапуск / Удаление

**Ссылка для клиента:**
```
vless://UUID@IP:8443?security=reality&sni=microsoft.com&fp=chrome&pbk=PUBLIC_KEY&sid=SHORT_ID&type=tcp&flow=xtls-rprx-vision
```

**Ограничение:** Reality не работает через Cloudflare CDN. Для CDN используйте WS+TLS.

## CDN режим (пункт 9)

При включении:
- Скачиваются актуальные IP подсети Cloudflare
- Прямой доступ к серверу блокируется (return 444)
- Real IP восстанавливается через заголовок `CF-Connecting-IP`
- Доступ только через Cloudflare Proxy

**Важно:** Включайте только после настройки домена через Cloudflare с включённым оранжевым облаком.

## WARP (пункты 10–14)

WARP применяется одновременно к обоим конфигам — WS и Reality.

**Split режим** (по умолчанию) — только выбранные домены через WARP:
```
openai.com
chatgpt.com
oaistatic.com
oaiusercontent.com
auth0.openai.com
```

**Global режим** — весь трафик через WARP.

**WARP Watchdog (пункт 30)** — cron каждые 2 минуты проверяет SOCKS5 и переподключает если WARP отвалился.

## SSL сертификаты

**Метод 1 — Cloudflare DNS API** (рекомендуется):
- Порт 80 не нужен
- Требуются Email и Global API Key Cloudflare

**Метод 2 — Standalone**:
- Временно открывает порт 80 через хуки UFW
- Не требует API ключей

Автообновление через `/etc/cron.d/acme-renew` — раз в 35 дней в 3:00.

## Приватность

- Access логи Xray отключены (`"access": "none"`)
- Sniffing выключен — сервер не читает содержимое трафика
- Домены назначения не логируются
- loglevel: `error` — только критические ошибки

## Сетевые параметры (применяются автоматически)

```
net.ipv4.icmp_echo_ignore_all = 1       # Anti-Ping IPv4
net.ipv6.icmp.echo_ignore_all = 1       # Anti-Ping IPv6
net.ipv6.conf.all.disable_ipv6 = 1      # Отключить IPv6
net.ipv6.conf.default.disable_ipv6 = 1  # Отключить IPv6
net.ipv6.conf.lo.disable_ipv6 = 1       # Отключить IPv6 loopback
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
```

IPv6 отключается системно — это гарантирует что весь исходящий трафик идёт по IPv4, независимо от настроек Xray. Nginx при этом настраивается только на `listen 443` без `[::]:443`.

## Структура файлов

```
/etc/nginx/
├── nginx.conf
├── conf.d/
│   ├── xray.conf                    # VLESS+WS сервер
│   ├── default.conf                 # Заглушка для прямых IP
│   ├── cloudflare_whitelist.conf    # Geo-модуль CF IP
│   └── cloudflare_real_ips.conf     # Real IP restore
└── cert/
    ├── cert.pem / cert.key          # SSL сертификат
    └── default.crt / default.key   # Самоподписанный

/usr/local/etc/xray/
├── config.json          # Конфиг VLESS+WS
├── reality.json         # Конфиг VLESS+Reality
├── reality_client.txt   # Параметры клиента Reality
└── warp_domains.txt     # Домены для WARP split

/etc/systemd/system/
├── xray.service         # VLESS+WS сервис
└── xray-reality.service # Reality сервис

/etc/cron.d/
├── acme-renew           # Автообновление SSL
├── clear-logs           # Автоочистка логов
└── warp-watchdog        # Мониторинг WARP

/etc/sysctl.d/
└── 99-xray.conf         # Anti-ping, IPv6 off, somaxconn
```

## Решение проблем

### WARP не подключается
```bash
systemctl restart warp-svc
sleep 5
warp-cli --accept-tos connect
warp-cli --accept-tos status
```

### Reality сервис не запускается
```bash
systemctl status xray-reality
journalctl -u xray-reality -n 50
xray -test -config /usr/local/etc/xray/reality.json
```

### Nginx не запускается после отключения IPv6
```bash
# Убрать listen [::]:443 из конфига
sed -i '/listen \[::\]:443/d' /etc/nginx/conf.d/xray.conf
nginx -t && systemctl reload nginx
```

### SSL истёк
```bash
vwn  # Пункт 7 или пункт 28
```

### Трафик идёт по IPv6 несмотря на настройки
```bash
# Применить системное отключение IPv6
sysctl -p /etc/sysctl.d/99-xray.conf
# Проверить
curl -s https://api.ipify.org
```

### Все устройства лагают через роутер
Используйте Reality (пункт 31) вместо WS+TLS — меньше оверхед, стабильнее на слабом железе.

## Удаление

```bash
vwn  # Пункт 26
```

Удаляет: Xray, Nginx, WARP, оба конфига, все cron задачи, сервисы, sysctl настройки.

## Зависимости

- [Xray-core](https://github.com/XTLS/Xray-core)
- [Cloudflare WARP](https://1.1.1.1/)
- [acme.sh](https://github.com/acmesh-official/acme.sh)
- nginx, jq, ufw, fail2ban, qrencode

## Лицензия

MIT License
