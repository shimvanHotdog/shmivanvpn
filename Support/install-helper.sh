#!/bin/sh
# Run as root (the app runs it through an administrator prompt).
#   install-helper.sh <app Resources dir> <username>
set -eu
PATH=/usr/bin:/bin:/usr/sbin:/sbin
RES="${1:?resources dir}"
USERNAME="${2:?username}"
DIR=/Library/PrivilegedHelperTools

mkdir -p "$DIR/vpnbar-assets"
install -o root -g wheel -m 755 "$RES/xray" "$DIR/vpnbar-xray"
install -o root -g wheel -m 755 "$RES/vpnbar-tun.sh" "$DIR/vpnbar-tun"
for f in geoip.dat geosite.dat; do
  install -o root -g wheel -m 644 "$RES/$f" "$DIR/vpnbar-assets/$f"
done
chown root:wheel "$DIR/vpnbar-assets"; chmod 755 "$DIR/vpnbar-assets"

TMP=$(mktemp)
printf '%s ALL=(root) NOPASSWD: %s/vpnbar-tun\n' "$USERNAME" "$DIR" > "$TMP"
visudo -cf "$TMP" >/dev/null
install -o root -g wheel -m 440 "$TMP" /etc/sudoers.d/vpnbar
rm -f "$TMP"
echo installed
