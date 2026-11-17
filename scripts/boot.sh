#!/usr/bin/env bash
# 起两个网关：opencode2api v1.4.8 (:8080) 与 zen-direct v0.9.37 (:8081)。
# 两者都打到 https://opencode.ai/inference 匿名免费层，出口就是这台 runner 的公网 IP。
set -Eeuo pipefail

ROOT="${GITHUB_WORKSPACE:-$PWD}"
RUN="$ROOT/run"
mkdir -p "$RUN"
cd "$ROOT"

chmod +x bin/zen-direct bin/o2a-v148

# opencode2api 的配置：匿名免费层、直连（用 runner 自己的出口）、不开 WARP、不开 WebUI。
cat > "$ROOT/o2a.json" <<'JSON'
{
  "listen": "127.0.0.1:8080",
  "server_keys": ["h2h-key"],
  "anonymous": true,
  "prefer": "zen",
  "warp": { "enabled": false },
  "proxies": ["direct"],
  "upstream": { "anonymous": "https://opencode.ai/inference" },
  "retry": { "max_attempts": 3, "timeout_seconds": 300 },
  "models": { "refresh_seconds": 300, "free_only": false, "active_probes": false },
  "performance": {
    "connect_timeout_seconds": 5,
    "failure_cooldown_seconds": 15,
    "max_anonymous_exits": 1,
    "free_tier_block_seconds": 900
  },
  "logging": { "level": "info" },
  "webui": { "enabled": false }
}
JSON

./bin/o2a-v148 -config "$ROOT/o2a.json" >"$RUN/o2a.log" 2>&1 &
echo $! > "$RUN/o2a.pid"

PORT=8081 \
LOG_FILE="$RUN/zen.log" \
DIRECT_DIAG=1 \
DIRECT_DEBUG=0 \
DIRECT_CONCURRENCY=16 \
DIRECT_FREELIMIT_COOLDOWN=0 \
DIRECT_FRESH_PER_TURN=0 \
ZEN_TLS=bun \
DIRECT_SIDECAR=off \
./bin/zen-direct >"$RUN/zen.out" 2>&1 &
echo $! > "$RUN/zen.pid"

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
wait_ok "http://127.0.0.1:8080/healthz" o2a 150 || rc=1
wait_ok "http://127.0.0.1:8081/health"  zen 150 || rc=1

echo "--- egress ip ---"
curl -s --max-time 10 --noproxy '*' https://api.ipify.org || true
echo
echo "--- o2a log (head) ---"
head -n 20 "$RUN/o2a.log" || true
echo "--- zen log (head) ---"
head -n 20 "$RUN/zen.out" || true
echo "--- zen gateway log (head) ---"
head -n 20 "$RUN/zen.log" 2>/dev/null || true

exit "$rc"
