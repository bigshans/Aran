#!/usr/bin/env bash
# Start/stop the isolated development kernel.
#
# Runs a *second* mihomo instance next to whatever client you already use:
#   - user-space, no TUN, no root
#   - mixed-port 7891 (your client probably uses 1080)
#   - external-controller 127.0.0.1:9090, secret aran-dev
#   - config copied from ~/.config/sparkle/work/config.yaml
#
# Usage: scripts/dev-core.sh start|stop|status
set -euo pipefail

SRC_CONFIG="${SRC_CONFIG:-$HOME/.config/sparkle/work/config.yaml}"
DEV_DIR="/tmp/aran-dev"
MIHOMO="${MIHOMO:-/usr/bin/mihomo}"
PIDFILE="$DEV_DIR/mihomo.pid"

case "${1:-status}" in
  start)
    if curl -s -m 1 -H 'Authorization: Bearer aran-dev' http://127.0.0.1:9090/version >/dev/null 2>&1; then
      echo "dev core already running"; exit 0
    fi
    rm -rf "$DEV_DIR"; mkdir -p "$DEV_DIR"
    python3 - "$SRC_CONFIG" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
src = re.sub(r'^mixed-port:.*$', 'mixed-port: 7891', src, count=1, flags=re.M)
src = re.sub(r'^allow-lan:.*$', 'allow-lan: false', src, count=1, flags=re.M)
src = re.sub(r'^geo-auto-update:.*$', 'geo-auto-update: false', src, flags=re.M)
if not re.search(r'^external-controller:', src, re.M):
    src = src.replace('log-level: info',
                      'external-controller: 127.0.0.1:9090\nsecret: aran-dev\nlog-level: info', 1)
open('/tmp/aran-dev/config.yaml', 'w').write(src)
PY
    for f in country.mmdb Country.mmdb geoip.dat geosite.dat ASN.mmdb geoip.metadb; do
      [ -e "$(dirname "$SRC_CONFIG")/$f" ] && ln -sf "$(dirname "$SRC_CONFIG")/$f" "$DEV_DIR/$f" || true
    done
    [ -d "$(dirname "$SRC_CONFIG")/ruleset" ] && cp -r "$(dirname "$SRC_CONFIG")/ruleset" "$DEV_DIR/" || true
    nohup "$MIHOMO" -d "$DEV_DIR" > "$DEV_DIR/mihomo.log" 2>&1 &
    echo $! > "$PIDFILE"
    sleep 3
    curl -s -m 3 -H 'Authorization: Bearer aran-dev' http://127.0.0.1:9090/version && echo " <- dev core up"
    ;;
  stop)
    [ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE")" 2>/dev/null || pkill -f "mihomo -d $DEV_DIR" || true
    rm -f "$PIDFILE"; rm -rf "$DEV_DIR"; echo "stopped"
    ;;
  status)
    curl -s -m 2 -H 'Authorization: Bearer aran-dev' http://127.0.0.1:9090/version || echo "not running"
    echo
    ;;
esac
