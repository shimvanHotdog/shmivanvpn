#!/bin/sh
# VPNBar privileged helper. Installed root-owned at /Library/PrivilegedHelperTools/vpnbar-tun
# and allowed via /etc/sudoers.d/vpnbar, so the menu bar app can start/stop TUN mode without a password.
#   vpnbar-tun start <config.json> [--dns]
#   vpnbar-tun stop
#   vpnbar-tun status
set -eu
PATH=/usr/bin:/bin:/usr/sbin:/sbin

DIR=/Library/PrivilegedHelperTools
XRAY="$DIR/vpnbar-xray"
ASSETS="$DIR/vpnbar-assets"
RUN=/var/run/vpnbar
PIDF="$RUN/xray.pid"
DNSBAK="$RUN/dns.bak"
LOG=/var/log/vpnbar-xray.log

services() {
  networksetup -listallnetworkservices | tail -n +2 | grep -v '^\*'
}

dns_set() {
  : > "$DNSBAK"
  services | while IFS= read -r svc; do
    cur=$(networksetup -getdnsservers "$svc" | tr '\n' ' ')
    case "$cur" in *"aren't any"*) cur="Empty" ;; esac
    printf '%s\t%s\n' "$svc" "$cur" >> "$DNSBAK"
    networksetup -setdnsservers "$svc" "$1" || true
  done
  dscacheutil -flushcache; killall -HUP mDNSResponder 2>/dev/null || true
}

dns_restore() {
  [ -f "$DNSBAK" ] || return 0
  while IFS="$(printf '\t')" read -r svc servers; do
    # shellcheck disable=SC2086
    networksetup -setdnsservers "$svc" $servers || true
  done < "$DNSBAK"
  rm -f "$DNSBAK"
  dscacheutil -flushcache; killall -HUP mDNSResponder 2>/dev/null || true
}

running() {
  [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF")" 2>/dev/null
}

stop() {
  if running; then
    pid=$(cat "$PIDF")
    kill "$pid" 2>/dev/null || true
    i=0
    while kill -0 "$pid" 2>/dev/null && [ $i -lt 30 ]; do sleep 0.1; i=$((i+1)); done
    kill -9 "$pid" 2>/dev/null || true
  fi
  rm -f "$PIDF"
  dns_restore
}

case "${1:-}" in
start)
  src="${2:?config path required}"
  # Only accept a regular file owned by the invoking user (not a symlink to something else).
  [ -f "$src" ] && [ ! -L "$src" ] || { echo "bad config path" >&2; exit 2; }
  [ "$(stat -f %u "$src")" = "${SUDO_UID:-0}" ] || { echo "config not owned by caller" >&2; exit 2; }
  stop
  mkdir -p "$RUN"; chmod 700 "$RUN"
  cp "$src" "$RUN/config.json"; chmod 600 "$RUN/config.json"
  # Second config overrides any log file paths, so a config can't make root write arbitrary files.
  printf '{"log":{"loglevel":"warning","access":"none","error":"","dnsLog":false}}' > "$RUN/override.json"
  : > "$LOG"; chmod 644 "$LOG"
  XRAY_LOCATION_ASSET="$ASSETS" nohup "$XRAY" run -c "$RUN/config.json" -c "$RUN/override.json" >> "$LOG" 2>&1 &
  echo $! > "$PIDF"
  sleep 1
  if ! running; then echo "xray exited, see $LOG" >&2; rm -f "$PIDF"; exit 1; fi
  [ "${3:-}" = "--dns" ] && dns_set 1.1.1.1
  echo started
  ;;
stop)
  stop; echo stopped ;;
status)
  if running; then echo running; else echo stopped; exit 1; fi ;;
*)
  echo "usage: $0 start <config> [--dns] | stop | status" >&2; exit 64 ;;
esac
