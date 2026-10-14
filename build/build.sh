#!/usr/bin/env bash
# Сборка пакета zapret2-warp-r6-fix из официальных релизов апстрима.
#   bash build/build.sh [версия]      например: bash build/build.sh v1.0.0
# Результат: dist/<PKG_NAME>-<версия>.zip и .sha256
# Нужны: bash, curl, unzip, zip, git, sha256sum, python3 (есть на ubuntu-latest).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=versions.env
source "$ROOT/build/versions.env"

VERSION="${1:-dev}"
VERSION="${VERSION//\//-}"
WORK="$ROOT/work"
DIST="$ROOT/dist"
PKG="$DIST/$PKG_NAME"

log() { printf '\n=== %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

rm -rf "$WORK" "$DIST"
mkdir -p "$WORK" "$PKG"/{bin,lua,files,lists,LICENSES}

# ---------------------------------------------------------------------------
log "zapret2 $ZAPRET2_VERSION: скачиваю и проверяю sha256"
Z2URL="https://github.com/bol-van/zapret2/releases/download/$ZAPRET2_VERSION"
curl -fsSL --retry 3 -o "$WORK/zapret2.zip" "$Z2URL/zapret2-$ZAPRET2_VERSION.zip"
curl -fsSL --retry 3 -o "$WORK/sha256sum.txt" "$Z2URL/sha256sum.txt"
echo "$ZAPRET2_ZIP_SHA256  $WORK/zapret2.zip" | sha256sum -c - || die "sha256 архива zapret2 не совпал с versions.env"
unzip -q "$WORK/zapret2.zip" -d "$WORK/z2"
Z2="$WORK/z2/zapret2-$ZAPRET2_VERSION"
[ -d "$Z2" ] || die "в архиве нет каталога zapret2-$ZAPRET2_VERSION"
# каждый бинарник Windows сверяем со списком sha256 из релиза
( cd "$WORK/z2" && grep -E "binaries/windows-x86_64/" "$WORK/sha256sum.txt" | sha256sum -c - ) || die "sha256 бинарников zapret2 не совпали"

WINBIN="$Z2/binaries/windows-x86_64"
cp "$WINBIN"/{winws2.exe,cygwin1.dll,WinDivert.dll,WinDivert64.sys,killall.exe} "$PKG/bin/"
cp "$Z2"/lua/{zapret-lib.lua,zapret-antidpi.lua,zapret-auto.lua} "$PKG/lua/"
cp "$Z2"/files/fake/*.bin "$PKG/files/"
cp "$Z2/docs/LICENSE.txt" "$PKG/LICENSES/zapret2-LICENSE.txt"

# ---------------------------------------------------------------------------
log "Flowseal $FLOWSEAL_REF: фейки и списки"
git clone -q --depth 1 --branch "$FLOWSEAL_REF" https://github.com/Flowseal/zapret-discord-youtube.git "$WORK/flowseal"
FS="$WORK/flowseal"
# фейки Flowseal (stun2.bin, tls_clienthello_max_ru.bin, ACTIVE_*.bin, ...); одноименные файлы zapret2 не перетираем
for f in "$FS"/bin/*.bin; do
  [ -e "$PKG/files/$(basename "$f")" ] || cp "$f" "$PKG/files/"
done
for f in list-general.txt list-google.txt list-exclude.txt ipset-exclude.txt; do
  cp "$FS/lists/$f" "$PKG/lists/$f"
done
# полный ipset Flowseal (то, что кладет "Update IPSet List" в service.bat)
cp "$FS/.service/ipset-service.txt" "$PKG/lists/ipset-all.txt"
cp "$FS/LICENSE.txt" "$PKG/LICENSES/Flowseal-LICENSE.txt"

# ---------------------------------------------------------------------------
log "Скрипты и списки этого репозитория"
cp "$ROOT"/src/*.cmd "$ROOT"/src/*.ps1 "$ROOT"/src/*.txt "$PKG/"
cp "$ROOT"/src/lists/*.txt "$PKG/lists/"
cp "$ROOT/LICENSE" "$PKG/LICENSES/zapret2-warp-r6-fix-LICENSE.txt"
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$PKG/LICENSES/"
mkdir -p "$PKG/queue/done" "$PKG/results"

# Windows-файлы: CRLF (на случай, если git отдал LF)
python3 - "$PKG" <<'PY'
import os, sys
root = sys.argv[1]
for dirpath, _, files in os.walk(root):
    for n in files:
        if os.path.splitext(n)[1].lower() in ('.cmd', '.bat', '.ps1', '.txt'):
            p = os.path.join(dirpath, n)
            b = open(p, 'rb').read()
            nb = b.replace(b'\r\n', b'\n').replace(b'\n', b'\r\n')
            if nb != b:
                open(p, 'wb').write(nb)
PY

# ---------------------------------------------------------------------------
log "Проверка: все файлы, на которые ссылаются bat, на месте"
need=(bin/winws2.exe bin/cygwin1.dll bin/WinDivert.dll bin/WinDivert64.sys
      lua/zapret-lib.lua lua/zapret-antidpi.lua lua/zapret-auto.lua
      files/stun2.bin files/tls_clienthello_max_ru.bin files/quic_initial_www_google_com.bin
      files/ACTIVE_DISCORD_UDP.bin files/ACTIVE_GAME_UDP.bin files/tls_clienthello_vk_com.bin
      files/tls_clienthello_gosuslugi_ru.bin files/tls_clienthello_www_google_com.bin
      lists/ipset-warp4.txt lists/list-general.txt lists/list-general-user.txt lists/list-google.txt
      lists/list-exclude.txt lists/list-exclude-user.txt lists/ipset-all.txt lists/ipset-exclude.txt
      lists/ipset-exclude-user.txt)
for f in "${need[@]}"; do [ -s "$PKG/$f" ] || die "нет файла $f"; done
[ "$(grep -cvE '^\s*(#|$)' "$PKG/lists/ipset-all.txt")" -gt 1000 ] || die "ipset-all.txt подозрительно короткий"

# ---------------------------------------------------------------------------
log "Проверка командных строк через nfqws2 --dry-run (тот же релиз zapret2, Linux)"
NFQ="$Z2/binaries/linux-x86_64/nfqws2"
chmod +x "$NFQ"
VAL="$WORK/validate"
mkdir -p "$VAL"
python3 - "$PKG" "$VAL" <<'PY'
import os, re, sys, shlex
pkg, out = sys.argv[1], sys.argv[2]
lua, files, lists = pkg + '/lua/', pkg + '/files/', pkg + '/lists/'

def subst(s):
    return (s.replace('%LUA%', lua).replace('%FILES%', files).replace('%LISTS%', lists)
             .replace('{LUA}\\', lua).replace('{FILES}\\', files).replace('{LISTS}\\', lists)
             .replace('{FLOWSEAL_LISTS}\\', lists))

def strip_wf(args):
    return [a for a in args if not a.startswith('--wf-')]

cases = []
# 1) готовые bat: аргументы winws2 после "start ... winws2.exe"
for name in sorted(os.listdir(pkg)):
    if not name.startswith('zapret2-') or not name.endswith('.cmd'):
        continue
    text = open(os.path.join(pkg, name), encoding='utf-8').read().replace('\r\n', '\n')
    m = re.search(r'^start .*?winws2\.exe" (.*?)\n\n', text, re.S | re.M)
    if not m:
        sys.exit('не найден вызов winws2 в ' + name)
    line = m.group(1).replace(' ^\n', ' ')
    cases.append((name, strip_wf(shlex.split(subst(line)))))

# 2) все стратегии из warp-strategies.txt с префиксами тестера
base = ['--lua-init=@' + lua + 'zapret-lib.lua', '--lua-init=@' + lua + 'zapret-antidpi.lua',
        '--lua-init=@' + lua + 'zapret-auto.lua']
for k, f in [('tls_max', 'tls_clienthello_max_ru.bin'), ('tls_google', 'tls_clienthello_www_google_com.bin'),
             ('tls_vk', 'tls_clienthello_vk_com.bin'), ('tls_gosuslugi', 'tls_clienthello_gosuslugi_ru.bin'),
             ('stun2', 'stun2.bin'), ('quic_google', 'quic_initial_www_google_com.bin'),
             ('game_udp', 'ACTIVE_GAME_UDP.bin'), ('discord_udp', 'ACTIVE_DISCORD_UDP.bin')]:
    base.append('--blob=%s:@%s%s' % (k, files, f))
pre = {'T': '--filter-l3=ipv4 --filter-tcp=443 --ipset=%sipset-warp4.txt --out-range=-d10' % lists,
       'U': '--filter-l3=ipv4 --filter-udp=443,500,1701,2408,4443,4500,8095,8443 --ipset=%sipset-warp4.txt --out-range=-n10' % lists,
       'X': ''}
for raw in open(os.path.join(pkg, 'warp-strategies.txt'), encoding='utf-8'):
    l = raw.strip()
    if not l or l.startswith('#') or l.startswith(';'):
        continue
    p = [x.strip() for x in l.split('|', 3)]
    if len(p) < 4:
        continue
    sid, proto, _, args = p
    cases.append((sid, base + shlex.split(pre.get(proto, '') + ' ' + subst(args))))

# статическая проверка, которую не делает --dry-run: существуют ли Lua-функции и блобы
funcs = set()
for lf in os.listdir(lua):
    if lf.endswith('.lua'):
        funcs |= set(re.findall(r'^function\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(', open(lua + lf, encoding='utf-8').read(), re.M))
errors = []
for name, args in cases:
    blobs = {'fake_default_tls', 'fake_default_http', 'fake_default_quic'}
    for a in args:
        m = re.match(r'--blob=([A-Za-z_][A-Za-z0-9_]*):', a)
        if m:
            blobs.add(m.group(1))
        for v in re.findall(r'desync\.([A-Za-z_][A-Za-z0-9_]*)\s*=', a):
            blobs.add(v)
    for a in args:
        if not a.startswith('--lua-desync='):
            continue
        parts = a[len('--lua-desync='):].split(':')
        if parts[0] not in funcs:
            errors.append('%s: нет Lua-функции %s' % (name, parts[0]))
        for kv in parts[1:]:
            k, _, v = kv.partition('=')
            if k in ('blob', 'seqovl_pattern', 'pattern') or (k == 'seqovl' and v.startswith('#')):
                b = v.lstrip('#')
                if b and not b.startswith('0x') and not b.isdigit() and b not in blobs:
                    errors.append('%s: неизвестный блоб %s в %s' % (name, b, kv))
if errors:
    sys.exit('\n'.join(errors))

with open(os.path.join(out, 'cases.txt'), 'w') as fo:
    for name, args in cases:
        fo.write(name + '\t' + '\x1f'.join(args) + '\n')
print('cases:', len(cases))
PY
fail=0
while IFS=$'\t' read -r name args; do
  IFS=$'\x1f' read -r -a argv <<< "$args"
  if res=$("$NFQ" --qnum=200 --dry-run "${argv[@]}" 2>&1); then
    printf '  OK    %s\n' "$name"
  else
    printf '  FAIL  %s: %s\n' "$name" "$(printf '%s' "$res" | tail -2 | tr '\n' ' ')"
    fail=1
  fi
done < "$VAL/cases.txt"
[ "$fail" = 0 ] || die "есть ошибки в командных строках"

# ---------------------------------------------------------------------------
log "Упаковка"
{
  echo "$PKG_NAME $VERSION"
  echo "zapret2 $ZAPRET2_VERSION (sha256 zip $ZAPRET2_ZIP_SHA256)"
  echo "Flowseal/zapret-discord-youtube $FLOWSEAL_REF ($(git -C "$FS" rev-parse HEAD))"
  echo "built $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  ( cd "$PKG" && find . -type f ! -name VERSION.txt | sort | xargs sha256sum )
} > "$PKG/VERSION.txt"
python3 - "$PKG/VERSION.txt" <<'PY'
import sys
p = sys.argv[1]; b = open(p, 'rb').read()
open(p, 'wb').write(b.replace(b'\r\n', b'\n').replace(b'\n', b'\r\n'))
PY

ZIP="$PKG_NAME-$VERSION.zip"
( cd "$DIST" && zip -q -r -X "$ZIP" "$PKG_NAME" && sha256sum "$ZIP" > "$ZIP.sha256" )
log "Готово: dist/$ZIP"
cat "$DIST/$ZIP.sha256"
