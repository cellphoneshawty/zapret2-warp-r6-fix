Zapret2 - Warp+R6 fix
=====================

Готовая сборка zapret2 (bol-van) для Cloudflare One Client (WARP) + YouTube/Discord.
Полное описание: README.md в репозитории на GitHub.

ЗАПУСК
  0. Распакуйте в папку без кириллицы и пробелов, например C:\zapret2-warp.
  1. Cloudflare One Client -> MASQUE поверх HTTP/2 (командная строка от администратора):
       warp-cli tunnel protocol set MASQUE
       warp-cli tunnel masque-options set h2-only
  2. zapret2-WARP.cmd -> "Да" в UAC. Появится свернутое окно "zapret2: WARP".
  3. Подключите Cloudflare One Client. Проверка: https://www.cloudflare.com/cdn-cgi/trace -> warp=on
  Остановка: закрыть окно "zapret2: WARP".
  Не запускайте одновременно с Flowseal (winws.exe), GoodbyeDPI и т.п.

ЕСЛИ НЕ РАБОТАЕТ
  - zapret2-WARP-ALT.cmd (фулинг badseq вместо ts).
  - RUN-TEST.cmd: перебор стратегий из warp-strategies.txt (20-40 минут),
    итог в results\run_*.result.txt, рабочие строки помечены PASS.
  - RUN-AGENT.cmd: тот же тестер, ждет задания *.job в queue\ (формат в README.md).

ФАЙЛЫ
  bin\     winws2.exe, cygwin1.dll, WinDivert*  (официальный релиз zapret2)
  lua\     zapret-lib.lua, zapret-antidpi.lua, zapret-auto.lua
  files\   фейки zapret2 и Flowseal
  lists\   ipset-warp4.txt (IP Cloudflare One Client), списки Flowseal, *-user.txt - ваши
  LICENSES\  лицензии компонентов
  VERSION.txt  версии апстрима и sha256 всех файлов
