#!/usr/bin/env bash
# 同一台 runner（同一个出口 IP）上，让 zen-direct 与 opencode2api 各打一发同样的请求。
# 顺序由 ORDER 决定，用于抵消"先进先出烧配额"的顺序效应。
#   输出：每条一行 H2H_RESULT {json}
set -Eeuo pipefail

SHAPE="${1:?shape}"
ORDER="${2:?order}"     # zen_first | o2a_first
REP="${3:-1}"
ROOT="${GITHUB_WORKSPACE:-$PWD}"

ZEN_BASE="http://127.0.0.1:${ZEN_PORT:-8081}"
O2A_BASE="http://127.0.0.1:${O2A_PORT:-8080}"
ZEN_KEY="${ZEN_KEY:-public}"
O2A_KEY="${O2A_KEY:-h2h-key}"
PAYLOAD="$ROOT/payloads/${SHAPE}.json"
OUT="$ROOT/run"
mkdir -p "$OUT"

[ -s "$PAYLOAD" ] || { echo "missing payload $PAYLOAD"; exit 2; }

say() { printf '%s %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }

egress_ip() {
  curl -s --max-time 10 --noproxy '*' https://api.ipify.org 2>/dev/null || true
}

# 一次请求。把 HTTP 码、耗时、响应体前 400 字节、关键响应头落成一条 JSON 行。
probe() {
  local bin="$1" base="$2" key="$3" seq="$4"
  local body="$OUT/${bin}-${SHAPE}-${REP}.body" hdr="$OUT/${bin}-${SHAPE}-${REP}.hdr"
  local code ms t0 t1
  t0="$(date +%s%3N)"
  code="$(curl -sS -o "$body" -w '%{http_code}' --noproxy '*' --max-time 240 \
      -H 'Content-Type: application/json' \
      -H "Authorization: Bearer $key" \
      -H 'User-Agent: zen-probe' \
      --dump-header "$hdr" \
      --data-binary "@$PAYLOAD" \
      "$base/v1/chat/completions" 2>"$OUT/${bin}-${SHAPE}-${REP}.err" || echo 000)"
  t1="$(date +%s%3N)"
  ms=$(( t1 - t0 ))
  [ -s "$body" ] || : > "$body"
  python3 - "$bin" "$code" "$ms" "$seq" "$SHAPE" "$ORDER" "$REP" "$body" "$hdr" <<'PY'
import json, sys
binname, code, ms, seq, shape, order, rep, bodypath, hdrpath = sys.argv[1:10]
raw = open(bodypath, 'rb').read()
text = raw[:400].decode('utf-8', 'replace').replace('\r', ' ').replace('\n', ' ')
full = raw.decode('utf-8', 'replace')
try:
    hdr = open(hdrpath, 'rb').read().decode('utf-8', 'replace')
except OSError:
    hdr = ''
retry = ''
for line in hdr.splitlines():
    low = line.lower()
    if low.startswith('retry-after:') or low.startswith('cf-ray:') or low.startswith('x-request-id:'):
        retry += line.strip() + ' | '

cls = 'ok'
if code == '200':
    if '"tool_calls"' in full or '"choices"' in full or '"delta"' in full:
        cls = 'ok_sse' if full.lstrip().startswith(('data:', 'event:')) else 'ok_json'
    else:
        cls = 'ok_unknown'
else:
    t = full
    if 'FreeUsageLimitError' in t or 'free_usage' in t.lower() or 'freeusagelimit' in t.lower():
        cls = 'free_limit'
    elif 'invalid local API key' in t:
        cls = 'local_auth'
    elif code.startswith('5'):
        cls = 'upstream_5xx'
    elif code == '000':
        cls = 'timeout'
    elif code == '429':
        cls = 'limit_429_other'
    else:
        cls = 'other_' + code

print('H2H_RESULT ' + json.dumps({
    'shape': shape, 'order': order, 'rep': int(rep), 'seq': int(seq),
    'bin': binname, 'code': code, 'class': cls, 'ms': int(ms),
    'retry_after': retry.strip(), 'body': text,
}, ensure_ascii=False, separators=(',', ':')))
PY
}

wait_ok() {
  local url="$1" name="$2" deadline=$((SECONDS + ${3:-150}))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if [ "$(curl -s -o /dev/null -w '%{http_code}' --noproxy '*' --max-time 5 "$url" || true)" = "200" ]; then
      say "$name ready ($url)"; return 0
    fi
    sleep 2
  done
  say "$name NOT ready after wait"
  return 1
}

IP="$(egress_ip)"
say "egress=$IP shape=$SHAPE order=$ORDER rep=$REP"

if [ "$ORDER" = "zen_first" ]; then
  probe zen "$ZEN_BASE"  "$ZEN_KEY" 1
  probe o2a "$O2A_BASE" "$O2A_KEY" 2
else
  probe o2a "$O2A_BASE" "$O2A_KEY" 1
  probe zen "$ZEN_BASE"  "$ZEN_KEY" 2
fi

echo "H2H_META $(python3 -c 'import json,sys;print(json.dumps({"egress":sys.argv[1]}))' "${IP:-}")"
