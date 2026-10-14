#requires -version 5.1
<#
  zapret2 (winws2) + Cloudflare One Client: перебор стратегий.

  Запуск (от администратора, удобнее через RUN-TEST.cmd / RUN-AGENT.cmd):
    .\test-warp.ps1                       все T-стратегии из warp-strategies.txt
    .\test-warp.ps1 -Only T01,T05         только выбранные
    .\test-warp.ps1 -Proto U              UDP-стратегии (MASQUE HTTP/3 / WireGuard)
    .\test-warp.ps1 -Agent                режим агента: ждет задания *.job в папке queue\

  Для каждой стратегии:
    1) запускает winws2 только на IP Cloudflare One Client (lists\ipset-warp4.txt);
    2) при выключенном WARP проверяет TLS до входной точки MASQUE, engage и API;
    3) warp-cli connect, ждет Connected;
    4) через туннель: cdn-cgi/trace (warp=on) и скачивание 2 МБ (ловит "заморозку 16 КБ");
    5) держит соединение -Hold секунд, снова проверяет статус и качает 2 МБ;
    6) warp-cli disconnect, останавливает winws2.
  Результаты: results\*.log и results\*.result.txt
#>
param(
  [string[]]$Only = @(),
  [string]$Proto = 'T',
  [int]$ConnectTimeout = 30,
  [int]$Hold = 15,
  [switch]$NoBaseline,
  [switch]$Agent,
  [int]$AgentIdleMinutes = 180
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

$Root    = $PSScriptRoot
$Bin     = Join-Path $Root 'bin'
$Lua     = Join-Path $Root 'lua'
$Files   = Join-Path $Root 'files'
$Lists   = Join-Path $Root 'lists'
$Queue   = Join-Path $Root 'queue'
$Done    = Join-Path $Queue 'done'
$Results = Join-Path $Root 'results'
foreach ($d in @($Queue, $Done, $Results)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }

$Winws2  = Join-Path $Bin 'winws2.exe'
$Curl    = Join-Path $env:SystemRoot 'System32\curl.exe'
$StratFile = Join-Path $Root 'warp-strategies.txt'
$WarpIpset = Join-Path $Lists 'ipset-warp4.txt'

$Stamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
$script:Log = Join-Path $Results "session_$Stamp.log"

$WfWarp   = '--wf-tcp-out=443 --wf-udp-out=443,500,1701,2408,4443,4500,8095,8443'
$WfSites  = '--wf-tcp-out=80,443,2053,2083,2087,2096,8443 --wf-udp-out=443,19294-19344,50000-50100'
$PrefixT  = "--filter-l3=ipv4 --filter-tcp=443 --ipset=`"$WarpIpset`" --out-range=-d10"
$PrefixU  = "--filter-l3=ipv4 --filter-udp=443,500,1701,2408,4443,4500,8095,8443 --ipset=`"$WarpIpset`" --out-range=-n10"

$BlobMap = [ordered]@{
  tls_max       = 'tls_clienthello_max_ru.bin'
  tls_google    = 'tls_clienthello_www_google_com.bin'
  tls_vk        = 'tls_clienthello_vk_com.bin'
  tls_gosuslugi = 'tls_clienthello_gosuslugi_ru.bin'
  stun2         = 'stun2.bin'
  quic_google   = 'quic_initial_www_google_com.bin'
  game_udp      = 'ACTIVE_GAME_UDP.bin'
  discord_udp   = 'ACTIVE_DISCORD_UDP.bin'
}

# ---------------------------------------------------------------------------
function Write-Log {
  param([string]$Text, [string]$Color = 'Gray')
  $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Text
  Write-Host $line -ForegroundColor $Color
  Add-Content -Path $script:Log -Value $line -Encoding UTF8
}

function Test-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Find-WarpCli {
  $c = Get-Command 'warp-cli.exe' -ErrorAction SilentlyContinue
  if ($c) { return $c.Source }
  foreach ($p in @("$env:ProgramFiles\Cloudflare\Cloudflare WARP\warp-cli.exe",
                   "$env:ProgramFiles\Cloudflare\Cloudflare One\warp-cli.exe",
                   "$env:ProgramFiles\Cloudflare\Cloudflare One Client\warp-cli.exe")) {
    if (Test-Path $p) { return $p }
  }
  $f = Get-ChildItem -Path "$env:ProgramFiles\Cloudflare" -Recurse -Filter 'warp-cli.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($f) { return $f.FullName }
  return $null
}

$script:WarpTos = $true
function Invoke-Warp {
  param([string[]]$A)
  if ($script:WarpTos) {
    $o = (& $script:WarpCli --accept-tos @A 2>&1 | ForEach-Object { "$_" }) -join "`n"
    if ($o -notmatch "unexpected argument|unrecognized|wasn't expected|Found argument") { return $o.Trim() }
    $script:WarpTos = $false
  }
  $o = (& $script:WarpCli @A 2>&1 | ForEach-Object { "$_" }) -join "`n"
  return $o.Trim()
}

function Get-WarpStatus {
  $t = Invoke-Warp @('status')
  $state = 'Other'
  if     ($t -match '(?im)Status(?: update)?:\s*Connected\b')    { $state = 'Connected' }
  elseif ($t -match '(?im)Status(?: update)?:\s*Disconnected\b') { $state = 'Disconnected' }
  elseif ($t -match '(?im)Status(?: update)?:\s*Connecting\b')   { $state = 'Connecting' }
  return [pscustomobject]@{ State = $state; Text = (($t -split "\r?\n") | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join ' / ' }
}

function Wait-WarpState {
  param([string]$Want, [int]$Timeout)
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $st = Get-WarpStatus
  while ($st.State -ne $Want -and $sw.Elapsed.TotalSeconds -lt $Timeout) {
    Start-Sleep -Milliseconds 1000
    $st = Get-WarpStatus
  }
  return [pscustomobject]@{ State = $st.State; Text = $st.Text; Seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1) }
}

function Disconnect-Warp {
  $st = Get-WarpStatus
  if ($st.State -ne 'Disconnected') {
    Invoke-Warp @('disconnect') | Out-Null
    Wait-WarpState -Want 'Disconnected' -Timeout 12 | Out-Null
  }
}

function Invoke-Curl {
  param([string]$Url, [string[]]$Extra = @(), [int]$Timeout = 7)
  $a = @('-sS', '-o', 'NUL', '--ssl-no-revoke', '--max-time', "$Timeout",
         '-w', '%{http_code}|%{size_download}|%{time_total}|%{speed_download}') + $Extra + @($Url)
  $out = (& $Curl @a 2>&1 | ForEach-Object { "$_" }) -join "`n"
  $rc = $LASTEXITCODE
  $m = [regex]::Match($out, '(\d{3})\|(\d+)\|([\d\.,]+)\|([\d\.,]+)\s*$')
  $code = ''; $size = [int64]0; $time = ''; $speed = [double]0
  if ($m.Success) {
    $code = $m.Groups[1].Value; $size = [int64]$m.Groups[2].Value; $time = $m.Groups[3].Value
    $speed = [double]($m.Groups[4].Value -replace ',', '.')
  }
  $err = ([regex]::Match($out, 'curl: \(\d+\)[^\r\n]*')).Value
  return [pscustomobject]@{ Rc = $rc; Code = $code; Size = $size; Time = $time; Speed = $speed; Err = $err }
}

function Get-CurlText {
  param([string]$Url, [int]$Timeout = 7)
  return ((& $Curl -s --ssl-no-revoke --max-time $Timeout $Url 2>&1 | ForEach-Object { "$_" }) -join "`n")
}

function Format-Curl($c) {
  switch ($c.Rc) {
    0  { return "OK($($c.Code))" }
    60 { return 'OK-CERT' }
    28 { if ($c.Size -gt 0) { return "TIMEOUT@$($c.Size)B" } else { return 'TIMEOUT' } }
    35 { return 'TLS-FAIL' }
    56 { return 'RESET' }
    52 { return 'EMPTY' }
    7  { return 'NOCONN' }
    6  { return 'DNS-FAIL' }
    default { return "ERR$($c.Rc)" }
  }
}

function Format-Download($c, [int64]$Expected) {
  if ($c.Rc -eq 0 -and $c.Size -eq $Expected) { return ('OK {0:N1}MB/s' -f ($c.Speed / 1MB)) }
  return ('FAIL rc={0} {1}B' -f $c.Rc, $c.Size)
}

function Expand-Ph([string]$s) {
  # {FLOWSEAL_LISTS}: списки Flowseal. В готовой сборке они лежат в lists\ рядом со скриптом,
  # в старой раскладке (zapret2 внутри папки Flowseal) - в ..\lists
  $fl = $Lists
  if (-not (Test-Path (Join-Path $Lists 'list-general.txt'))) { $fl = Join-Path (Split-Path $Root -Parent) 'lists' }
  return $s.Replace('{LISTS}', $Lists).Replace('{FILES}', $Files).Replace('{ROOT}', $Root).Replace('{FLOWSEAL_LISTS}', $fl)
}

function Get-BaseArgs([string]$Wf) {
  $p = @($Wf,
    "--lua-init=@`"$Lua\zapret-lib.lua`"",
    "--lua-init=@`"$Lua\zapret-antidpi.lua`"",
    "--lua-init=@`"$Lua\zapret-auto.lua`"")
  foreach ($k in $BlobMap.Keys) {
    $f = Join-Path $Files $BlobMap[$k]
    if (Test-Path $f) { $p += "--blob=${k}:@`"$f`"" } else { Write-Log "нет файла блоба $f" 'Yellow' }
  }
  return ($p -join ' ')
}

function Start-Winws2 {
  param([string]$ProfileArgs, [string]$Tag, [string]$RunDir, [string]$Wf)
  $cmdline = (Get-BaseArgs $Wf) + ' ' + $ProfileArgs
  $safe = $Tag -replace '[^\w\-]', '_'
  $so = Join-Path $RunDir "winws2_$safe.out.txt"
  $se = Join-Path $RunDir "winws2_$safe.err.txt"
  Set-Content -Path (Join-Path $RunDir "winws2_$safe.cmdline.txt") -Value $cmdline -Encoding UTF8
  $p = Start-Process -FilePath $Winws2 -ArgumentList $cmdline -WorkingDirectory $Bin -NoNewWindow -PassThru `
        -RedirectStandardOutput $so -RedirectStandardError $se
  Start-Sleep -Milliseconds 2500
  if ($p.HasExited) {
    $e = ''
    foreach ($f in @($se, $so)) { if (Test-Path $f) { $e += (Get-Content $f -Raw -ErrorAction SilentlyContinue) + ' ' } }
    return [pscustomobject]@{ Proc = $null; Error = ($e -replace '\s+', ' ').Trim() }
  }
  return [pscustomobject]@{ Proc = $p; Error = '' }
}

function Stop-Winws2($w) {
  if ($w -and $w.Proc -and -not $w.Proc.HasExited) {
    Stop-Process -Id $w.Proc.Id -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 700
  }
}

function Stop-Conflicts {
  foreach ($n in @('winws', 'winws2')) {
    $ps = Get-Process -Name $n -ErrorAction SilentlyContinue
    if ($ps) {
      Write-Log "Останавливаю $n.exe (PID $(($ps | ForEach-Object Id) -join ','))" 'Yellow'
      $ps | Stop-Process -Force -ErrorAction SilentlyContinue
    }
  }
  foreach ($svc in @('zapret', 'zapret2', 'winws1', 'winws2')) {
    $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
    if ($s -and $s.Status -eq 'Running') {
      Write-Log "Останавливаю службу $svc" 'Yellow'
      Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
    }
  }
  Start-Sleep -Milliseconds 800
}

function Read-StrategyLine([string]$l) {
  $p = $l -split '\|', 4
  if ($p.Count -lt 4) { return $null }
  return [pscustomobject]@{ Id = $p[0].Trim(); Proto = $p[1].Trim().ToUpper(); Desc = $p[2].Trim(); Args = $p[3].Trim() }
}

function Read-Strategies([string]$Path) {
  $list = New-Object System.Collections.ArrayList
  if (-not (Test-Path $Path)) { return $list }
  foreach ($line in (Get-Content -Path $Path -Encoding UTF8)) {
    $l = $line.Trim()
    if (-not $l -or $l.StartsWith('#') -or $l.StartsWith(';')) { continue }
    $s = Read-StrategyLine $l
    if ($s) { [void]$list.Add($s) }
  }
  return $list
}

function Get-ProfileArgs($S) {
  $a = Expand-Ph $S.Args
  switch ($S.Proto) {
    'T' { return "$PrefixT $a" }
    'U' { return "$PrefixU $a" }
    default { return $a }
  }
}

function Write-ResultHeader([string]$File) {
  $h = '{0,-5} {1,-8} {2,-10} {3,-10} {4,-10} {5,-4} {6,-6} {7,-5} {8,-18} {9,-18} {10}' -f 'ID','VERDICT','INGRESS','ENGAGE','API','CONN','SEC','TRACE','DL1','DL2','NOTE / ОПИСАНИЕ'
  Add-Content -Path $File -Value $h -Encoding UTF8
  Write-Host $h -ForegroundColor Cyan
}

function Write-ResultLine($r, [string]$File) {
  $note = $r.Note
  if ($note.Length -gt 160) { $note = $note.Substring(0, 160) + '...' }
  $line = '{0,-5} {1,-8} {2,-10} {3,-10} {4,-10} {5,-4} {6,-6} {7,-5} {8,-18} {9,-18} {10} | {11}' -f `
    $r.Id, $r.Verdict, $r.Ingress, $r.Engage, $r.Api, $r.Connect, $r.Sec, $r.Trace, $r.DL1, $r.DL2, $r.Desc, $note
  Add-Content -Path $File -Value $line -Encoding UTF8
  $color = 'Red'
  if ($r.Verdict -eq 'PASS') { $color = 'Green' } elseif ($r.Verdict -eq 'PARTIAL') { $color = 'Yellow' }
  Write-Host $line -ForegroundColor $color
}

# ---------------------------------------------------------------------------
function Test-WarpStrategy {
  param($S, [string]$RunDir, [int]$CTimeout, [int]$HoldSec)
  $r = [ordered]@{ Id = $S.Id; Verdict = 'FAIL'; Ingress = ''; Engage = ''; Api = ''; Connect = ''; Sec = '';
                   Trace = ''; DL1 = ''; DL2 = ''; Note = ''; Desc = $S.Desc }
  $w = $null
  Write-Log ("=== {0}: {1}" -f $S.Id, $S.Desc) 'Cyan'
  try {
    do {
      Disconnect-Warp
      if ($S.Id -ne 'BASE') {
        $w = Start-Winws2 -ProfileArgs (Get-ProfileArgs $S) -Tag $S.Id -RunDir $RunDir -Wf $WfWarp
        if (-not $w.Proc) {
          $r.Verdict = 'STARTERR'; $r.Note = $w.Error
          Write-Log "winws2 не запустился: $($w.Error)" 'Red'
          break
        }
      }
      $r.Ingress = Format-Curl (Invoke-Curl -Url 'https://consumer-masque.cloudflareclient.com/' `
                     -Extra @('--connect-to', 'consumer-masque.cloudflareclient.com:443:162.159.198.2:443'))
      $r.Engage  = Format-Curl (Invoke-Curl -Url 'https://engage.cloudflareclient.com/cdn-cgi/trace')
      $r.Api     = Format-Curl (Invoke-Curl -Url 'https://zero-trust-client.cloudflareclient.com/')
      Write-Log ("  без WARP: ingress={0} engage={1} api={2}" -f $r.Ingress, $r.Engage, $r.Api)

      Invoke-Warp @('connect') | Out-Null
      $c = Wait-WarpState -Want 'Connected' -Timeout $CTimeout
      $r.Sec = $c.Seconds
      if ($c.State -ne 'Connected') {
        $r.Connect = 'NO'; $r.Note = $c.Text
        Write-Log "  WARP не подключился за $CTimeout c: $($c.Text)" 'Red'
        break
      }
      $r.Connect = 'YES'
      Write-Log "  WARP Connected за $($c.Seconds) c" 'Green'
      Start-Sleep -Seconds 2
      $t = Get-CurlText -Url 'https://www.cloudflare.com/cdn-cgi/trace' -Timeout 8
      if ($t -match 'warp=(\w+)') { $r.Trace = $Matches[1] } else { $r.Trace = '?' }
      $d1 = Invoke-Curl -Url 'https://speed.cloudflare.com/__down?bytes=2000000' -Timeout 25
      $r.DL1 = Format-Download $d1 2000000
      Write-Log "  trace warp=$($r.Trace), загрузка 2МБ: $($r.DL1)"
      if ($HoldSec -gt 0) { Start-Sleep -Seconds $HoldSec }
      $st = Get-WarpStatus
      $d2 = Invoke-Curl -Url 'https://speed.cloudflare.com/__down?bytes=2000000' -Timeout 25
      $r.DL2 = Format-Download $d2 2000000
      if ($st.State -ne 'Connected') { $r.Note = "после удержания: $($st.Text)" }
      Write-Log "  через $HoldSec c: статус=$($st.State), загрузка 2МБ: $($r.DL2)"
      $ok1 = ($d1.Rc -eq 0 -and $d1.Size -eq 2000000)
      $ok2 = ($d2.Rc -eq 0 -and $d2.Size -eq 2000000)
      if ($ok1 -and $ok2 -and $st.State -eq 'Connected' -and $r.Trace -match '^(on|plus)$') { $r.Verdict = 'PASS' }
      else { $r.Verdict = 'PARTIAL' }
    } while ($false)
  }
  finally {
    Disconnect-Warp
    Stop-Winws2 $w
  }
  return [pscustomobject]$r
}

function Test-Sites {
  param([string]$Name, [string]$ProfileArgs, [string]$Wf, [string[]]$Urls, [string]$RunDir, [string]$File)
  Write-Log "=== сайты: $Name" 'Cyan'
  $w = $null
  $res = @()
  try {
    do {
      Disconnect-Warp
      if ($ProfileArgs) {
        $w = Start-Winws2 -ProfileArgs (Expand-Ph $ProfileArgs) -Tag "sites_$Name" -RunDir $RunDir -Wf $Wf
        if (-not $w.Proc) {
          Add-Content -Path $File -Value ("{0,-12} STARTERR {1}" -f $Name, $w.Error) -Encoding UTF8
          Write-Log "winws2 не запустился: $($w.Error)" 'Red'
          break
        }
      }
      foreach ($u in $Urls) {
        $c = Invoke-Curl -Url $u -Timeout 10
        $txt = Format-Curl $c
        $res += ('{0}={1}' -f $u, $txt)
        $line = '{0,-12} {1,-14} {2,10}B {3,7}s  {4}' -f $Name, $txt, $c.Size, $c.Time, $u
        Add-Content -Path $File -Value $line -Encoding UTF8
        if ($c.Rc -eq 0) { Write-Host $line -ForegroundColor Green } else { Write-Host $line -ForegroundColor Red }
      }
    } while ($false)
  }
  finally { Stop-Winws2 $w }
}

# ---------------------------------------------------------------------------
function Invoke-WarpRun {
  param($Strategies, [string]$Name, [bool]$Baseline, [int]$CTimeout, [int]$HoldSec)
  $runDir = Join-Path $Results $Name
  New-Item -ItemType Directory -Force -Path $runDir | Out-Null
  $resFile = Join-Path $Results "$Name.result.txt"
  Write-ResultHeader $resFile
  $all = @()
  if ($Baseline) {
    $all += [pscustomobject]@{ Id = 'BASE'; Proto = 'X'; Desc = 'без zapret (контроль)'; Args = '' }
  }
  $all += $Strategies
  $summary = @()
  foreach ($s in $all) {
    $r = Test-WarpStrategy -S $s -RunDir $runDir -CTimeout $CTimeout -HoldSec $HoldSec
    Write-ResultLine $r $resFile
    $summary += $r
  }
  Add-Content -Path $resFile -Value "--- готово $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -Encoding UTF8
  Write-Host ''
  Write-Host 'ИТОГ:' -ForegroundColor Cyan
  foreach ($r in $summary) {
    $color = 'Red'; if ($r.Verdict -eq 'PASS') { $color = 'Green' } elseif ($r.Verdict -eq 'PARTIAL') { $color = 'Yellow' }
    Write-Host ('  {0,-5} {1,-8} {2}' -f $r.Id, $r.Verdict, $r.Desc) -ForegroundColor $color
  }
  Write-Log "Результаты: $resFile" 'Cyan'
}

function Read-Job([string]$Path) {
  $job = [ordered]@{ Mode = 'warp'; Only = @(); Proto = $Proto; Timeout = $ConnectTimeout; Hold = $Hold; Baseline = $false;
                     Strategies = @(); Urls = @(); Variants = @(); Wf = $WfSites; Cmd = '' }
  foreach ($line in (Get-Content -Path $Path -Encoding UTF8)) {
    $l = $line.Trim()
    if (-not $l -or $l.StartsWith('#')) { continue }
    $i = $l.IndexOf(':')
    if ($i -lt 1) { continue }
    $k = $l.Substring(0, $i).Trim().ToLower()
    $v = $l.Substring($i + 1).Trim()
    switch ($k) {
      'mode'     { $job.Mode = $v.ToLower() }
      'only'     { $job.Only = @($v -split '[,\s]+' | Where-Object { $_ }) }
      'proto'    { $job.Proto = $v.ToUpper() }
      'timeout'  { $job.Timeout = [int]$v }
      'hold'     { $job.Hold = [int]$v }
      'baseline' { $job.Baseline = ($v -match '^(1|yes|true|y|да)$') }
      'strategy' { $s = Read-StrategyLine $v; if ($s) { $job.Strategies += $s } }
      'url'      { $job.Urls += $v }
      'variant'  { $p = $v -split '\|', 2; if ($p.Count -eq 2) { $job.Variants += [pscustomobject]@{ Name = $p[0].Trim(); Args = $p[1].Trim() } } }
      'wf'       { $job.Wf = $v }
      'cmd'      { $job.Cmd = $v.ToLower() }
    }
  }
  return [pscustomobject]$job
}

function Select-Strategies($All, [string[]]$OnlyIds, [string]$P) {
  if ($OnlyIds -and $OnlyIds.Count -gt 0) {
    $sel = @()
    foreach ($id in $OnlyIds) { $sel += @($All | Where-Object { $_.Id -eq $id }) }
    return $sel
  }
  return @($All | Where-Object { $_.Proto -eq $P -or $_.Proto -eq 'X' })
}

function Write-Environment {
  Write-Log "zapret2: $Winws2" 'Cyan'
  Write-Log "warp-cli: $script:WarpCli" 'Cyan'
  Write-Log ('warp-cli --version: ' + (Invoke-Warp @('--version')))
  $set = (Invoke-Warp @('settings')) + "`n" + (Invoke-Warp @('settings', 'list'))
  $interesting = ($set -split "\r?\n") | Where-Object { $_ -match '(?i)mode|protocol|masque|tunnel|wireguard|h2|h3|split|exclude|endpoint' } | Select-Object -Unique -First 25
  foreach ($l in $interesting) { Write-Log "  settings: $($l.Trim())" }
  Write-Log ('warp-cli status: ' + (Get-WarpStatus).Text)
  $ts = (netsh interface tcp show global) -join "`n"
  if ($ts -match '(?im)^.*(timestamps|метки времени|RFC 1323).*$') { Write-Log ('TCP: ' + $Matches[0].Trim()) }
}

# ---------------------------------------------------------------------------
if (-not (Test-Admin)) {
  Write-Host 'Нужны права администратора: запустите RUN-TEST.cmd или RUN-AGENT.cmd.' -ForegroundColor Red
  exit 1
}
if (-not (Test-Path $Winws2)) { Write-Host "Нет $Winws2" -ForegroundColor Red; exit 1 }
if (-not (Test-Path $Curl))   { Write-Host "Нет $Curl" -ForegroundColor Red; exit 1 }
$script:WarpCli = Find-WarpCli
if (-not $script:WarpCli) { Write-Host 'Не найден warp-cli.exe (Cloudflare One Client).' -ForegroundColor Red; exit 1 }

$Only = @($Only | ForEach-Object { $_ -split ',' } | Where-Object { $_ } | ForEach-Object { $_.Trim() })

Write-Log "Старт. Папка: $Root" 'Cyan'
Stop-Conflicts
Write-Environment

if (-not $Agent) {
  $all = Read-Strategies $StratFile
  $sel = Select-Strategies $all $Only $Proto
  Write-Log "Стратегий к тесту: $($sel.Count)" 'Cyan'
  Invoke-WarpRun -Strategies $sel -Name "run_$Stamp" -Baseline (-not $NoBaseline) -CTimeout $ConnectTimeout -HoldSec $Hold
  Disconnect-Warp
  Write-Log 'Готово. WARP оставлен отключенным, winws2 остановлен.' 'Cyan'
  exit 0
}

# ---------------- режим агента ----------------
$hb = Join-Path $Results 'agent.heartbeat.txt'
$lastJob = Get-Date
Write-Log "Режим агента: жду задания *.job в $Queue (выход: cmd: stop или $AgentIdleMinutes мин без заданий)" 'Cyan'
while ($true) {
  Set-Content -Path $hb -Value ("alive {0} pid {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $PID) -Encoding UTF8
  $jobs = @(Get-ChildItem -Path $Queue -Filter '*.job' -File -ErrorAction SilentlyContinue | Sort-Object Name)
  if ($jobs.Count -eq 0) {
    if (((Get-Date) - $lastJob).TotalMinutes -gt $AgentIdleMinutes) { Write-Log 'Долго нет заданий - выхожу.' 'Yellow'; break }
    Start-Sleep -Seconds 2
    continue
  }
  $jf = $jobs[0]
  $lastJob = Get-Date
  $name = [IO.Path]::GetFileNameWithoutExtension($jf.Name)
  Start-Sleep -Milliseconds 500
  Write-Log "Задание: $($jf.Name)" 'Cyan'
  $job = $null
  try { $job = Read-Job $jf.FullName } catch { Write-Log "Ошибка чтения задания: $_" 'Red' }
  $dest = Join-Path $Done ("{0}_{1}.job" -f $name, (Get-Date -Format 'HHmmss'))
  Move-Item -Path $jf.FullName -Destination $dest -Force -ErrorAction SilentlyContinue
  if (-not $job) { continue }
  if ($job.Cmd -eq 'stop') { Write-Log 'Получена команда stop.' 'Yellow'; break }
  try {
    if ($job.Mode -eq 'sites') {
      $runDir = Join-Path $Results $name
      New-Item -ItemType Directory -Force -Path $runDir | Out-Null
      $resFile = Join-Path $Results "$name.result.txt"
      if ($job.Baseline) { Test-Sites -Name 'NONE' -ProfileArgs '' -Wf $job.Wf -Urls $job.Urls -RunDir $runDir -File $resFile }
      foreach ($v in $job.Variants) { Test-Sites -Name $v.Name -ProfileArgs $v.Args -Wf $job.Wf -Urls $job.Urls -RunDir $runDir -File $resFile }
      Add-Content -Path $resFile -Value "--- готово $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -Encoding UTF8
    }
    else {
      $all = Read-Strategies $StratFile
      $sel = @()
      if ($job.Only.Count -gt 0) { $sel += Select-Strategies $all $job.Only $job.Proto }
      $sel += $job.Strategies
      if ($sel.Count -eq 0 -and -not $job.Baseline) { $sel = Select-Strategies $all @() $job.Proto }
      Invoke-WarpRun -Strategies $sel -Name $name -Baseline $job.Baseline -CTimeout $job.Timeout -HoldSec $job.Hold
    }
  }
  catch { Write-Log "Ошибка выполнения задания: $_" 'Red' }
  Disconnect-Warp
}
Write-Log 'Агент завершен.' 'Cyan'
