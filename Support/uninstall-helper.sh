#!/bin/sh
set -eu
PATH=/usr/bin:/bin:/usr/sbin:/sbin
DIR=/Library/PrivilegedHelperTools
[ -x "$DIR/vpnbar-tun" ] && "$DIR/vpnbar-tun" stop || true
rm -rf "$DIR/vpnbar-tun" "$DIR/vpnbar-xray" "$DIR/vpnbar-assets" /etc/sudoers.d/vpnbar /var/run/vpnbar
echo uninstalled
