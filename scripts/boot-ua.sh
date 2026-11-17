#!/usr/bin/env bash
# 起三个网关，用来判定 opencode2api 全 429 是不是 UA 版本造成的：
#   :8080  opencode2api v1.4.8 原版（v2ClientVersion = 2.1.1）
#   :8082  opencode2api v1.4.8 只改 v2ClientVersion = 2.3.0
#   :8081  zen-direct v0.9.38（对照，UA 自动跟到 npm 最新）
set -Eeuo pipefail

ROOT="${GITHUB_WORKSPACE:-$PWD}"
RUN="$ROOT/run"
mkdir -p "$RUN"
cd "$ROOT"

chmod +x bin/zen-direct bin/o2a-v148 bin/o2a-ua230

cat > "$ROOT/o2a.json" <<'JSON'
{
  "listen": "127.0.0.1:8080",
  "server_keys": ["h2h-key"],
  "anonymous": true,
  "prefer": "zen",
  "warp": { "enabled": false },
  "proxies": ["direct"],
  "upstream": { "anonymous": "https://opencode.ai/inference" },
  "retry": { "max_attempts": 1, "timeout_seconds": 300 },
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
sed 's#127.0.0.1:8080#127.0.0.1:8082#' "$ROOT/o2a.json" > "$ROOT/o2a-ua230.json"

./bin/o2a-v148 -config "$ROOT/o2a.json" >"$RUN/o2a.log" 2>&1 &
echo $! > "$RUN/o2a.pid"
./bin/o2a-ua230 -config "$ROOT/o2a-ua230.json" >"$RUN/o2a-ua230.log" 2>&1 &
echo $! > "$RUN/o2a-ua230.pid"

PORT=8081 \
LOG_FILE="$RUN/zen.log" \
DIRECT_DIAG=1 DIRECT_DEBUG=0 DIRECT_CONCURRENCY=16 \
DIRECT_FREELIMIT_COOLDOWN=0 DIRECT_FRESH_PER_TURN=0 \
ZEN_TLS=bun DIRECT_SIDECAR=off \
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
wait_ok "http://127.0.0.1:8080/healthz" o2a-stock 150 || rc=1
wait_ok "http://127.0.0.1:8082/healthz" o2a-ua230 150 || rc=1
wait_ok "http://127.0.0.1:8081/health"  zen 150 || rc=1

echo "--- egress ip ---"
curl -s --max-time 10 --noproxy '*' https://api.ipify.org || true
echo
exit "$rc"
