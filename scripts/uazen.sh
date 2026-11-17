#!/usr/bin/env bash
# 同一出口上按顺序打两个 zen 实例，隔离 UA 版本这一个变量。
#   LOW_FIRST | HIGH_FIRST   (LOW = 2.1.1 或 2.2.0，HIGH = 2.3.0)
set -Eeuo pipefail

LOW="${1:?2.1.1|2.2.0}"      # 低版本号
ORDER="${2:?low_first|high_first}"
REP="${3:-1}"
ROOT="${GITHUB_WORKSPACE:-$PWD}"
OUT="$ROOT/run"
PAYLOAD="$ROOT/payloads/plain.json"

port_of() {
  case "$1" in
    2.1.1) echo 8091 ;;
    2.2.0) echo 8092 ;;
    2.3.0) echo 8093 ;;
  esac
}

probe() {
  local ver="$1" seq="$2"
  local port body hdr code ms t0 t1
  port="$(port_of "$ver")"
  body="$OUT/zen-$ver-${LOW}-${REP}.body"
  hdr="$OUT/zen-$ver-${LOW}-${REP}.hdr"
  t0="$(date +%s%3N)"
  code="$(curl -sS -o "$body" -w '%{http_code}' --noproxy '*' --max-time 120 \
      -H 'Content-Type: application/json' \
      -H 'Authorization: Bearer public' \
      -H 'User-Agent: zen-probe' \
      --dump-header "$hdr" \
      --data-binary "@$PAYLOAD" \
      "http://127.0.0.1:$port/v1/chat/completions" 2>"$OUT/zen-$ver-$REP.err" || echo 000)"
  t1="$(date +%s%3N)"
  ms=$(( t1 - t0 ))
  [ -s "$body" ] || : > "$body"
  python3 - "$ver" "$code" "$ms" "$seq" "$REP" "$body" "$hdr" "$LOW" "$ORDER" <<'PY'
import json, sys
ver, code, ms, seq, rep, bodypath, hdrpath, low, order = sys.argv[1:10]
raw = open(bodypath, 'rb').read()
text = raw[:300].decode('utf-8', 'replace').replace('\r', ' ').replace('\n', ' ')
try:
    hdr = open(hdrpath, 'rb').read().decode('utf-8', 'replace')
except OSError:
    hdr = ''
retry = ''
for line in hdr.splitlines():
    if line.lower().startswith(('retry-after:', 'cf-ray:', 'x-request-id:')):
        retry += line.strip() + ' | '
if code == '200':
    cls = 'ok_json' if text.lstrip().startswith('{') else 'ok_sse'
elif 'FreeUsageLimitError' in text or 'Free usage limit' in text:
    cls = 'free_limit'
elif code == '000':
    cls = 'timeout'
else:
    cls = 'other_' + code
print('H2H_RESULT ' + json.dumps({
    'shape': 'ua_' + low, 'order': order, 'rep': int(rep), 'seq': int(seq),
    'bin': 'zen-' + ver, 'code': code, 'class': cls, 'ms': int(ms),
    'retry_after': retry.strip(), 'body': text,
}, ensure_ascii=False, separators=(',', ':')))
PY
}

IP="$(curl -s --max-time 10 --noproxy '*' https://api.ipify.org 2>/dev/null || true)"
echo "egress=$IP low=$LOW order=$ORDER rep=$REP"

if [ "$ORDER" = "low_first" ]; then
  probe "$LOW" 1
  probe 2.3.0 2
else
  probe 2.3.0 1
  probe "$LOW" 2
fi
