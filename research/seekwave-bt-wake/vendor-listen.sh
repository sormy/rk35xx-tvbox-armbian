#!/bin/sh
# Passive listener on the remote's two undocumented vendor channels.
#
# ae00: ae01 write-without-response + ae02 notify.  ae40: ae41 + ae42.  Both are the shape of a
# proprietary command protocol. Nothing here writes to the command halves - a write-only vendor
# attribute is also the shape of an OTA control point, and this is the box's only input device.
# Subscribing to the notify halves is free: if the remote ever volunteers anything, btmon records it.
set -u
MAC=${1:-74:CC:23:DE:9D:33}
D=/var/log/bt-trace; mkdir -p "$D"
T="$D/vendor-$(date +%Y%m%d-%H%M%S).btsnoop"

bluetoothctl info "$MAC" 2>/dev/null | grep -q "Connected: yes" || {
	echo "remote not connected - press a key first"; exit 1; }

pkill -x btmon 2>/dev/null; sleep 1
setsid nohup sh -c "exec btmon -w $T >/dev/null 2>&1" >/dev/null 2>&1 &
sleep 2

# bluetoothctl indents object paths with a tab, so anchor on the path itself
paths=$(bluetoothctl gatt.list-attributes "$MAC" 2>/dev/null |
	awk '/\/org\/bluez\// { p = $1 }
	     /0000ae02|0000ae42/ && p { print p; p = "" }')
[ -n "$paths" ] || { echo "no vendor notify characteristics found"; exit 1; }

for p in $paths; do
	echo "subscribing: $p"
	bluetoothctl >/dev/null 2>&1 <<-EOF
		gatt.select-attribute $p
		gatt.notify on
	EOF
done

echo "listening. trace: $T"
echo "use the remote normally; anything the vendor channels emit lands in that trace."
echo "read it with:  btmon -r $T | grep -A4 'Handle Value Notification'"
