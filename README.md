# Zapret2 - Warp+R6 fix

Готовая сборка [zapret2](https://github.com/bol-van/zapret2) (bol-van) для Windows, с которой **Cloudflare One Client (WARP)** снова подключается из России. Через WARP открываются серверы Rainbow Six Siege и Ubisoft Connect в целом, а также всё остальное, что без него не пускает. Без WARP сборка заодно открывает YouTube, Discord, Google и сайты на Cloudflare.

> Стратегия подобрана и проверена **у одного провайдера** (октябрь 2026). У вашего провайдера DPI может вести себя иначе. На этот случай в сборке есть тестер, который сам переберёт ~50 вариантов и покажет, какие работают.

## Быстрый старт

1. Скачайте `zapret2-warp-r6-fix-*.zip` из [Releases](../../releases) и распакуйте в папку **без кириллицы и пробелов**, например `C:\zapret2-warp`.
2. Остановите другие обходы DPI: Flowseal (`winws.exe` / служба `zapret`), GoodbyeDPI и т.п. Батник сам гасит `winws.exe` и службу `zapret` от Flowseal, но лучше проверить.
3. Переключите Cloudflare One Client на **MASQUE поверх HTTP/2**. Откройте командную строку от администратора:
   ```
   warp-cli tunnel protocol set MASQUE
   warp-cli tunnel masque-options set h2-only
   ```
   Если клиент ещё не зарегистрирован, сначала выполните `warp-cli registration new`.
4. Запустите **`zapret2-WARP.cmd`** и разрешите запуск от администратора. Появится свёрнутое окно `zapret2: WARP`.
5. Подключите Cloudflare One Client. Проверить, что трафик идёт через WARP, можно на https://www.cloudflare.com/cdn-cgi/trace — там должно быть `warp=on`.

Чтобы остановить, закройте окно `zapret2: WARP` (или `taskkill /f /im winws2.exe`).

## Если не подключается

1. Попробуйте **`zapret2-WARP-ALT.cmd`**. Это тот же приём, но с фулингом `badseq` вместо `ts`, и ему не нужны TCP timestamps.
2. Запустите **`RUN-TEST.cmd`**. Он перебирает стратегии из `warp-strategies.txt`. Для каждой тестер:
   - запускает `winws2` только на IP Cloudflare One Client;
   - проверяет TLS до точки входа MASQUE;
   - делает `warp-cli connect` и ждёт статус `Connected`;
   - через туннель проверяет `warp=on` и качает 2 МБ дважды с паузой (ловит «заморозку на 16 КБ»).

   Полный прогон идёт 20–40 минут. Интернет в это время будет моргать, а WARP — сам подключаться и отключаться. Итоговая таблица попадает в `results\run_*.result.txt`: строки `PASS` — рабочие варианты.
3. Нашли рабочую стратегию — замените строку `--lua-desync=...` профиля WARP (первый профиль) в `zapret2-WARP.cmd` на её аргументы.

**`RUN-AGENT.cmd`** — тот же тестер в режиме агента. Он ждёт файлы заданий `*.job` в папке `queue\`. Пример:

```
mode: warp
baseline: yes
only: T22,T43,T47
hold: 20
strategy: T99 | T | моя стратегия | --payload=tls_client_hello --lua-desync=fake:blob=stun2:tcp_ts=-600000:repeats=6
```

Есть и режим `mode: sites`: строки `url: ...` и `variant: имя | профили` проверяют сайты без WARP.

## Почему перестали работать стратегии Flowseal

По результатам тестов (подробно — в шапке `warp-strategies.txt`):

- Без обхода WARP висит на `Performing connectivity checks`.
- **Любой фейковый TLS ClientHello** (max.ru, google, vk, копия с подменой SNI, seqovl с TLS-паттерном, syndata) приводит к таймауту TLS до `162.159.198.x` и ошибке `Failed to perform happy eyeballs`. На этом держались `general (FAKE TLS AUTO)` и большинство стратегий Flowseal. Заодно они ломают сайты на Cloudflare и google.com.
- Нарезка ClientHello без фейков (multisplit/multidisorder) пропускает TLS, но WARP всё равно не поднимается.
- **Работает не-TLS фейк первым пакетом**: STUN (`stun2.bin`) или HTTP-запрос с фулингом `ts` или `badseq`. DPI считает поток другим протоколом и дальше его не трогает. WARP подключается за ~1 с, через туннель идёт 3–5 МБ/с.
- Фулинги `md5sig` и `autottl`, а также фейки из нулей или мусора не сработали.

## Что делает `zapret2-WARP.cmd`

| # | Трафик | Фильтр | Действие |
|---|--------|--------|----------|
| 1 | Cloudflare One Client (MASQUE h2, API) | `lists\ipset-warp4.txt`, TCP 443 | фейк STUN перед ClientHello |
| 2 | YouTube / Google | `list-google.txt`, TCP 443 | фейк STUN |
| 3 | Discord и др. | `list-general.txt` + `list-general-user.txt`, TCP 80/443 | фейк STUN |
| 4 | Discord media | `discord.media`, TCP 2053/2083/2087/2096/8443 | фейк STUN |
| 5 | QUIC | хостлисты, UDP 443 | фейк QUIC google |
| 6 | Голос Discord | STUN/discord, UDP 19294-19344, 50000-50100 | фейк |
| 7 | Cloudflare, Google и хостинги | `ipset-all.txt`, TCP 80/443/8443 | фейк STUN |

Свои домены добавляйте в `lists\list-general-user.txt`, исключения — в `list-exclude-user.txt` и `ipset-exclude-user.txt`. Листы перечитываются на лету.

Используется только IPv4. IPv6-адреса WARP лежат закомментированными в `lists\ipset-warp4.txt`.

## Сборка

Бинарники в репозитории не хранятся. GitHub Actions (`.github/workflows/build.yml`) на каждый тег `v*`:

1. скачивает официальный релиз **zapret2** и сверяет sha256 архива (`build/versions.env`) и каждого бинарника Windows (`sha256sum.txt` релиза);
2. берёт фейки и списки из тега **Flowseal/zapret-discord-youtube**. `ipset-all.txt` — это `.service/ipset-service.txt`, то самое, что скачивает «Update IPSet List»;
3. проверяет все командные строки (оба bat и все стратегии) через `nfqws2 --dry-run` из того же релиза zapret2;
4. собирает zip с `VERSION.txt` (версии и sha256 всех файлов) и публикует релиз.

Локально: `bash build/build.sh v1.0.0` (нужны bash, curl, unzip, zip, git, python3). Новый релиз — `git tag v1.0.1 && git push origin v1.0.1`.

## Благодарности и лицензии

- [bol-van/zapret2](https://github.com/bol-van/zapret2) — winws2, Lua-движок, фейки (MIT).
- [Flowseal/zapret-discord-youtube](https://github.com/Flowseal/zapret-discord-youtube) — списки доменов/IP и фейки `stun2.bin`, `tls_clienthello_max_ru.bin`, `ACTIVE_*.bin` (MIT).
- WinDivert (LGPLv3 / GPLv2) и cygwin1.dll (LGPLv3) поставляются в составе релиза zapret2 без изменений.

Скрипты этого репозитория распространяются по лицензии MIT (`LICENSE`), подробности по сторонним компонентам — в `THIRD_PARTY_NOTICES.md`.

WinDivert — драйвер перехвата трафика, и антивирусы иногда ругаются на него как на «хакерский инструмент». Это не вирус: его используют и zapret, и GoodbyeDPI. Сборка не ходит ни на какие сторонние серверы: весь обход делается локально, на вашем ПК.
