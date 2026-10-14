# Сторонние компоненты

Релизный zip собирается из официальных релизов апстрима без изменений бинарников.

| Компонент | Откуда | Лицензия |
|-----------|--------|----------|
| winws2.exe, killall.exe, lua/*.lua, files/*.bin (фейки zapret2) | [bol-van/zapret2](https://github.com/bol-van/zapret2), релиз из `build/versions.env` | MIT, `LICENSES/zapret2-LICENSE.txt` |
| WinDivert.dll, WinDivert64.sys | [WinDivert](https://reqrypt.org/windivert.html) (basil00), в составе релиза zapret2 | LGPLv3 или GPLv2 на выбор; исходники: https://github.com/basil00/WinDivert |
| cygwin1.dll | [Cygwin](https://cygwin.com), в составе релиза zapret2 | LGPLv3 (с исключением Cygwin); исходники: https://cygwin.com/git/ |
| files/stun2.bin, tls_clienthello_max_ru.bin, ACTIVE_*.bin и др., lists/list-*.txt, lists/ipset-*.txt | [Flowseal/zapret-discord-youtube](https://github.com/Flowseal/zapret-discord-youtube), тег из `build/versions.env` | MIT, `LICENSES/Flowseal-LICENSE.txt` |

Собственные файлы репозитория (bat/cmd, `test-warp.ps1`, `warp-strategies.txt`, `lists/ipset-warp4.txt`, сборочные скрипты) распространяются по лицензии MIT (`LICENSE`).
