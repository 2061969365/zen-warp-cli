#!/usr/bin/env bash
# 三个 zen-direct v0.9.38 实例，只差 DIRECT_UA_VERSION：
#   :8091  2.1.1
#   :8092  2.2.0
#   :8093  2.3.0
set -Eeuo pipefail

ROOT="${GITHUB_WORKSPACE:-$PWD}"
RUN="$ROOT/run"
mkdir -p "$RUN"
cd "$ROOT"
chmod +x bin/zen-direct

start_one() {
  local port="$1" ver="$2"
  PORT="$port" \
  LOG_FILE="$RUN/zen-$ver.log" \
  DIRECT_UA_VERSION="$ver" \
  DIRECT_DIAG=1 DIRECT_DEBUG=0 DIRECT_CONCURRENCY=8 \
  DIRECT_FREELIMIT_COOLDOWN=0 DIRECT_FRESH_PER_TURN=0 \
  ZEN_TLS=bun DIRECT_SIDECAR=off \
  ./bin/zen-direct >"$RUN/zen-$ver.out" 2>&1 &
  echo $! > "$RUN/zen-$ver.pid"
}

start_one 8091 2.1.1
start_one 8092 2.2.0
start_one 8093 2.3.0

wait_ok() {
  local url="$1" name="$2" deadline=$((SECONDS + ${3:-150}))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if [ "$(curl -s -o /dev/null -w '%{http_code}' --noproxy '*' --max-time 5 "$url" || true)" = "200" ]; then
      echo "READY $name $url"; return 0
    fi
    sleep 2
  done
  echo "NOT_READY $name $url"
  return 1
}

rc=0
wait_ok "http://127.0.0.1:8091/health" zen-2.1.1 150 || rc=1
wait_ok "http://127.0.0.1:8092/health" zen-2.2.0 150 || rc=1
wait_ok "http://127.0.0.1:8093/health" zen-2.3.0 150 || rc=1

echo "--- egress ip ---"
curl -s --max-time 10 --noproxy '*' https://api.ipify.org || true
echo
grep -h "serving as" "$RUN"/zen-*.log 2>/dev/null | tail -n 3 || true
exit "$rc"
