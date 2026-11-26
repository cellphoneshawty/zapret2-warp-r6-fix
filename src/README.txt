zapret2 (bol-van) v1.0.5 + Cloudflare One Client  —  C:\Antizapret\zapret2
==========================================================================

ЗАПУСК
  zapret2-WARP.cmd       основной. Фейк STUN перед TLS ClientHello, фулинг ts.
  zapret2-WARP-ALT.cmd   запасной. Тот же фейк, фулинг badseq (без TCP timestamps).
  Оба сами просят права администратора, останавливают winws.exe / службу zapret
  от Flowseal и запускают winws2.exe свернутым окном "zapret2: WARP".
  Дальше просто подключаешь Cloudflare One Client (режим MASQUE, HTTP/2).
  Остановить: закрыть окно "zapret2: WARP" (или taskkill /f /im winws2.exe).
  Flowseal и zapret2 одновременно НЕ запускать.

ЧТО ВЫЯСНИЛИ (тесты 13-14.10.2026, results\*.result.txt)
  - Без обхода WARP висит на "Performing connectivity checks".
  - Любой фейковый TLS ClientHello (max.ru, google, vk, копия с подменой SNI,
    seqovl с TLS-паттерном, syndata) -> TLS до 162.159.198.2 таймаутит,
    "Failed to perform happy eyeballs". Поэтому умерла FAKE TLS AUTO.
  - Нарезка ClientHello (multisplit/multidisorder) без фейков: TLS проходит,
    но WARP не поднимается.
  - Работает НЕ-TLS фейк первым пакетом: STUN (stun2.bin) или HTTP-запрос.
    DPI считает поток другим протоколом и дальше его не трогает.
      PASS: stun2 + ts (x1, x3, x6), stun2 + badseq, HTTP-фейк + ts,
            stun2 + max.ru (только если stun2 идет ПЕРВЫМ), stun2 + нарезка.
      FAIL: stun2 + md5sig, stun2 + autottl, нулевые байты, ACTIVE_GAME_UDP.
  - Итоговые конфиги: WARP Connected за ~1 c, удержание 60 c, 2 МБ через
    туннель ~3-5 МБ/с; без WARP открываются github, youtube, discord,
    cloudflare, google.com (без обхода google.com у тебя не открывается).

ПРОФИЛИ ИТОГОВОГО КОНФИГА
  1. WARP: lists\ipset-warp4.txt, TCP 443          -> fake stun2
  2. list-google.txt (YouTube), TCP 443           -> fake stun2
  3. list-general(-user).txt, TCP 80/443          -> fake stun2
  4. discord.media, TCP 2053/2083/2087/2096/8443  -> fake stun2
  5. QUIC (UDP 443) для хостлистов                -> fake quic google x6
  6. Discord voice (stun/discord, UDP 19294-19344, 50000-50100) -> fake
  7. ipset-all.txt, TCP 80/443/8443               -> fake stun2
  Листы 2-7 берутся из Flowseal: C:\Antizapret\lists.

ЕСЛИ СНОВА СЛОМАЕТСЯ
  1. Попробовать zapret2-WARP-ALT.cmd.
  2. Перебор: RUN-AGENT.cmd (агент ждет задания *.job в queue\) или
     RUN-TEST.cmd (сразу прогоняет все T-стратегии из warp-strategies.txt).
     Формат задания (queue\имя.job):
       mode: warp
       baseline: yes
       only: T22,T43,T47
       hold: 20
       strategy: T99 | T | описание | --payload=tls_client_hello --lua-desync=...
     Результаты: results\<имя>.result.txt, подробный лог: results\session_*.log
  3. warp-cli: протокол должен быть MASQUE + HTTP/2 (warp-cli settings).

ФАЙЛЫ
  bin\    winws2.exe, cygwin1.dll, WinDivert*  (официальный релиз, sha256 сверен)
  lua\    zapret-lib.lua, zapret-antidpi.lua, zapret-auto.lua
  files\  фейки zapret2 + stun2.bin, tls_clienthello_max_ru.bin, ACTIVE_*.bin из Flowseal
  lists\  ipset-warp4.txt (IP Cloudflare One Client, только IPv4)
  test-warp.ps1, warp-strategies.txt, RUN-*.cmd, queue\, results\ — тестовый стенд
