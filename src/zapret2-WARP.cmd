@echo off
chcp 65001 >nul
rem MAIN: STUN fake before ClientHello, fooling ts (needs TCP timestamps)
rem zapret2 (bol-van) v1.0.5 + Cloudflare One Client (MASQUE h2-only). Do not run together with Flowseal winws.exe. https://github.com/bol-van/zapret2
cd /d "%~dp0"
net session >nul 2>&1
if errorlevel 1 (
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)
tasklist /fi "imagename eq winws.exe" | find /i "winws.exe" >nul && (echo Stopping Flowseal winws.exe & taskkill /f /im winws.exe >nul)
tasklist /fi "imagename eq winws2.exe" | find /i "winws2.exe" >nul && (echo Stopping previous winws2.exe & taskkill /f /im winws2.exe >nul)
sc query zapret 2>nul | find /i "RUNNING" >nul && (echo Stopping Flowseal service zapret & net stop zapret >nul)
netsh interface tcp show global | findstr /i "timestamps" | findstr /i "enabled" >nul || netsh interface tcp set global timestamps=enabled >nul 2>&1

set "BIN=%~dp0bin\"
set "LUA=%~dp0lua\"
set "FILES=%~dp0files\"
set "LISTS=%~dp0lists\"

start "zapret2: WARP" /min "%BIN%winws2.exe" --wf-tcp-out=80,443,2053,2083,2087,2096,8443 --wf-udp-out=443,19294-19344,50000-50100 ^
--lua-init=@"%LUA%zapret-lib.lua" --lua-init=@"%LUA%zapret-antidpi.lua" ^
--blob=stun2:@"%FILES%stun2.bin" --blob=quic_google:@"%FILES%quic_initial_www_google_com.bin" --blob=discord_udp:@"%FILES%ACTIVE_DISCORD_UDP.bin" ^
--filter-l3=ipv4 --filter-tcp=443 --ipset="%LISTS%ipset-warp4.txt" --out-range=-d10 --payload=tls_client_hello --lua-desync=fake:blob=stun2:tcp_ts=-600000:repeats=6 --new ^
--filter-tcp=443 --hostlist="%LISTS%list-google.txt" --out-range=-d10 --payload=tls_client_hello --lua-desync=fake:blob=stun2:tcp_ts=-600000:repeats=6 --new ^
--filter-tcp=80,443 --hostlist="%LISTS%list-general.txt" --hostlist="%LISTS%list-general-user.txt" --hostlist-exclude="%LISTS%list-exclude.txt" --hostlist-exclude="%LISTS%list-exclude-user.txt" --out-range=-d10 --payload=tls_client_hello,http_req --lua-desync=fake:blob=stun2:tcp_ts=-600000:repeats=6 --new ^
--filter-tcp=2053,2083,2087,2096,8443 --hostlist-domains=discord.media --out-range=-d10 --payload=tls_client_hello --lua-desync=fake:blob=stun2:tcp_ts=-600000:repeats=6 --new ^
--filter-udp=443 --hostlist="%LISTS%list-google.txt" --hostlist="%LISTS%list-general.txt" --hostlist="%LISTS%list-general-user.txt" --hostlist-exclude="%LISTS%list-exclude.txt" --hostlist-exclude="%LISTS%list-exclude-user.txt" --payload=quic_initial --lua-desync=fake:blob=quic_google:repeats=6 --new ^
--filter-udp=19294-19344,50000-50100 --filter-l7=discord,stun --payload=stun,discord_ip_discovery --lua-desync=fake:blob=discord_udp:repeats=6 --new ^
--filter-tcp=80,443,8443 --ipset="%LISTS%ipset-all.txt" --ipset-exclude="%LISTS%ipset-exclude.txt" --ipset-exclude="%LISTS%ipset-exclude-user.txt" --hostlist-exclude="%LISTS%list-exclude.txt" --hostlist-exclude="%LISTS%list-exclude-user.txt" --out-range=-d10 --payload=tls_client_hello,http_req --lua-desync=fake:blob=stun2:tcp_ts=-600000:repeats=6

echo zapret2 started (minimized window "zapret2: WARP"). Now connect Cloudflare One Client.
timeout /t 5 >nul
