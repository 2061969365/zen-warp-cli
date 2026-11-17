#!/usr/bin/env bash
# 同一出口 IP 上，把"只差 UA 版本"的两个 opencode2api 各打一发。
#   ua230_first | stock_first
set -Eeuo pipefail

FIRST="${1:?ua230_first|stock_first}"
REP="${2:-1}"
ROOT="${GITHUB_WORKSPACE:-$PWD}"
OUT="$ROOT/run"
PAYLOAD="$ROOT/payloads/plain.json"
mkdir -p "$OUT"

probe() {
  local bin="$1" base="$2" seq="$3"
  local body="$OUT/${bin}-ua-${REP}.body" hdr="$OUT/${bin}-ua-${REP}.hdr"
  local code ms t0 t1
  t0="$(date +%s%3N)"
  code="$(curl -sS -o "$body" -w '%{http_code}' --noproxy '*' --max-time 120 \
      -H 'Content-Type: application/json' \
      -H 'Authorization: Bearer h2h-key' \
      -H 'User-Agent: zen-probe' \
      --dump-header "$hdr" \
      --data-binary "@$PAYLOAD" \
      "$base/v1/chat/completions" 2>"$OUT/${bin}-ua-${REP}.err" || echo 000)"
  t1="$(date +%s%3N)"
  ms=$(( t1 - t0 ))
  [ -s "$body" ] || : > "$body"
  python3 - "$bin" "$code" "$ms" "$seq" "$REP" "$body" "$hdr" "$FIRST" <<'PY'
import json, sys
binname, code, ms, seq, rep, bodypath, hdrpath, order = sys.argv[1:9]
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
    'shape': 'plain', 'order': order, 'rep': int(rep), 'seq': int(seq),
    'bin': binname, 'code': code, 'class': cls, 'ms': int(ms),
    'retry_after': retry.strip(), 'body': text,
}, ensure_ascii=False, separators=(',', ':')))
PY
}

IP="$(curl -s --max-time 10 --noproxy '*' https://api.ipify.org 2>/dev/null || true)"
echo "egress=$IP first=$FIRST rep=$REP"

if [ "$FIRST" = "ua230_first" ]; then
  probe o2a-ua230 "http://127.0.0.1:8082" 1
  probe o2a-stock "http://127.0.0.1:8080" 2
else
  probe o2a-stock "http://127.0.0.1:8080" 1
  probe o2a-ua230 "http://127.0.0.1:8082" 2
fi
