# shoulderkop

[![build](https://github.com/BranchSeeker/shoulderkop/actions/workflows/build.yml/badge.svg)](https://github.com/BranchSeeker/shoulderkop/actions/workflows/build.yml)

«Плечо» для [podkop](https://github.com/itdoginfo/podkop): забирает подписку (Xray JSON или
список `vless://`), конвертирует серверы в sing-box outbound и раскладывает их по секциям
podkop. Своего туннеля не поднимает — только настраивает podkop.

## Как работает

1. Скачивает подписку (`curl`, UA `Happ/2.7.0`, `x-hwid` из MAC роутера).
2. Разбирает Xray JSON или список ссылок и превращает серверы в outbound-ы sing-box;
   неподдерживаемые узлы (обфусцированный xhttp, REALITY без публичного ключа) отбрасывает.
3. Раскладывает серверы по секциям podkop для выбранного режима и заполняет служебные поля —
   `source_network_interfaces`, `remote_domain_lists` / `remote_subnet_lists`, `community_lists`.
4. Перезагружает podkop, если конфигурация изменилась.

## Во что превращается подписка

```
Xray JSON / список vless://
        │
        ├── Обход БС (lte)          skop_lte + skop_lte_direct
        └── Домашний интернет (wifi) skop_yt + skop_eu
```

| Режим | Секции podkop | Что куда идёт |
|---|---|---|
| **Обход БС** (`lte`) | `skop_lte`, `skop_lte_direct` | весь LAN — в прокси; списки РКН (`geosite.srs`, `geoip.srs`) — напрямую; `fully_routed_ips` — LAN-подсеть + `127.0.0.1` |
| **Домашний интернет** (`wifi`) | `skop_yt`, `skop_eu` | `yt` — все WiFi-серверы (YouTube); `eu` — WiFi-серверы без группы «Россия/YouTube» (Telegram, Meta, Cloudflare, Roblox и т.п.); остальное — напрямую |

Секции `skop_yt` и `skop_eu` — это **urltest**-секции podkop: серверы лежат в
`urltest_proxy_links`, podkop сам переключается на лучший, интервал проверки по
умолчанию — 30 секунд. В WiFi-режиме обе секции всегда собираются как `urltest`
со vless-ссылками, без одиночных `outbound` и без балансировщиков. `xhttp`-узлы
отсеиваются жёстко: без `sing-box tools decode-link` podkop такие ссылки не
разбирает. В LTE-режиме поведение прежнее, там `xhttp` остаётся.

## Установка

Нужен OpenWrt 24.10+ (`apk` или `opkg`). Установщик сам ставит podkop, sing-box-extended и
shoulderkop и спрашивает только два раза: ставить ли extended и ссылку на подписку.

```sh
wget -O - https://github.com/BranchSeeker/shoulderkop/releases/latest/download/shoulderkop-install.sh | sh
```

```sh
wget -O /tmp/shoulderkop-install.sh https://github.com/BranchSeeker/shoulderkop/releases/latest/download/shoulderkop-install.sh
sh /tmp/shoulderkop-install.sh
```

Флаги и разбор ошибок — [installer/README.md](installer/README.md). Готовые пакеты —
в [релизах](https://github.com/BranchSeeker/shoulderkop/releases), сборка — в
[PACKAGING.md](PACKAGING.md).

### Списки сообщества (WiFi)

В режиме «Домашний интернет» списки podkop (`community_lists`) редактируются в LuCI —
отдельно для секции YouTube (`skop_yt`) и для секции остальных сервисов (`skop_eu`).
Набор и подписи те же, что в podkop (`github.com/itdoginfo/allow-domains`). При выборе
`russia_inside` несовместимые списки убираются: он уже включает YouTube, Geo Block, Block,
Porn, News, Anime, HDRezka, Tik-Tok и другие.

Пока списки не меняли, действуют прежние значения по умолчанию: `youtube` для `skop_yt`
и `russia_inside, telegram, meta, cloudflare, hodca, roblox` для `skop_eu`. В режиме
«Обход БС» списки сообщества не используются — там свои `.srs` Белые списки РКН.

## Если подписка истекла

Истёкшая подписка отличается от временной ошибки панели. Признаки, которые понимает
shoulderkop:

- заглушка Remnawave — два `vless://`-узла с нулевым UUID на `0.0.0.0:1` и именами
  «Приложение не подходит» / «Рекомендуется Happ»;
- HTTP 404/410 на ссылке подписки;
- `subscription-userinfo: …; expire=<unix>` в прошлом — только если настоящих серверов
  в ответе нет;
- явный текст ответа («subscription expired», «user not found» и т.п.).

Настоящие серверы важнее заголовка `expire`: если панель ещё отдаёт рабочие узлы,
подписка считается активной (бывает grace-период после даты окончания).

Что происходит при истёкшей подписке:

1. podkop и sing-box останавливаются, их автозапуск (`/etc/rc.d/S*podkop`,
   `S*sing-box`) снимается;
2. секции podkop и настройки не удаляются — конфиг ждёт активации;
3. cron-задача `shoulderkop update` остаётся и продолжает проверять подписку;
4. как только в ответе снова появляется хотя бы один настоящий сервер, конфигурация
   применяется, автозапуск возвращается, podkop и sing-box стартуют.

Для автоматического возврата должно быть включено «Обновлять по расписанию»: без cron
проверять подписку будет некому. Сетевые ошибки и HTTP 5xx истечением не считаются —
в этом случае туннель остаётся как есть, а в статусе пишется `status: "error"`.

Состояние видно в LuCI и в `shoulderkop status`: `status: "expired"`, `suspended: true`,
`suspended_at`, `actions`, `userinfo.expire`.

Если удалить shoulderkop, пока туннель на паузе, автозапуск podkop и sing-box останется
выключенным (это состояние хранится в `/etc/config/shoulderkop`) — верните его вручную:
`/etc/init.d/podkop enable`.

## Несколько подписок

Ссылок можно добавить несколько. В LuCI — кнопкой «＋» рядом с полем подписки, в
конфиге — список `subscription_url` (можно повторять `--url=` в `shoulderkop update`).

- Каждая ссылка проверяется отдельно, а узлы всех активных складываются в общий пул;
  одинаковые серверы не дублируются.
- Истёкшая или битая ссылка (404/410, заглушка панели) просто не даёт серверов —
  туннель продолжает работать на остальных.
- Пауза (остановка podkop/sing-box и снятие автозапуска) включается, только когда
  истекли **все** ссылки.
- Если часть ссылок ответила сетевой ошибкой, статус `error` и туннель не трогается —
  даже когда остальные истекли: неизвестно, подписка кончилась или панель недоступна.
- Когда активных подписок стало меньше (одна истекла или её убрали из списка), секции
  podkop пересобираются один раз: на серверах исчезнувшей подписки клиента с его uuid
  уже удалили, и держать их в конфиге незачем. Сетевые ошибки поводом не считаются.
- После такой пересборки секции, которые нечем заполнить, не создаются: их трафик идёт
  напрямую. Ручные правки в `skop_*`-секциях при этом теряются (они и так перезаписываются
  при каждом обновлении).
- LuCI показывает статус каждой ссылки: активна / истекла / ошибка, с датой окончания.

Число активных подписок хранится в `/etc/config/shoulderkop` (`last_active_subs`),
поэтому однократная пересборка срабатывает и после перезагрузки роутера. При обновлении
со старой версии счётчика ещё нет: если в этот момент одна из ссылок уже истекла, один
раз нажмите «Обновить конфигурацию».

## Использование

LuCI → **Сервисы → Shoulderkop**: ссылка подписки, режим, списки сообщества для WiFi и
кнопка «Обновить подписку».

```sh
shoulderkop update            # скачать подписку, разложить по секциям podkop
shoulderkop update --rebuild  # то же, но с пересозданием всех секций skop_*
shoulderkop status            # последний отчёт, пауза и состояние сервисов
shoulderkop list_servers      # серверы из кэша
shoulderkop links             # outbounds подписки → vless:// ссылки
shoulderkop convert FILE      # разобрать файл подписки: active / expired / empty
```

`links` — обратная операция к конвертеру. По умолчанию берёт узлы из кэша
подписки и печатает ссылки для текущего режима; `--section=yt|eu|lte` оставляет
одну секцию, `--file=SUB` читает файл подписки, `--json` добавляет имена узлов.
С `--podkop` ссылки собираются из уже разложенных секций podkop (включая
синтетические `urltest`-группы):

```sh
shoulderkop links --section=yt
shoulderkop links --podkop --json
```

Списки сообщества можно передать и из командной строки (для режима `wifi`):

```sh
shoulderkop update --mode=wifi \
  --yt-lists=youtube \
  --eu-lists=russia_inside,telegram,meta,cloudflare,hodca,roblox
```

Пример проверки заглушки без роутера:

```sh
curl -s -A 'Happ/2.7.0' https://sub.example.com/TOKEN > /tmp/sub.txt
shoulderkop convert /tmp/sub.txt
# {"status":"expired","placeholder":true,"count":2,...}
```
