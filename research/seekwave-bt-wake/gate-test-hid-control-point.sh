#!/bin/sh
# Does this remote honour the HID Control Point? The whole minimal design rests on it.
#
# Writes 0x00 (host entering Suspend) and watches what the remote does. No suspend involved, so a
# failure costs nothing. Cheap handsets commonly expose 0x2A4C to satisfy the profile and ignore the
# value, so presence proves nothing — only a behaviour change does.
#
#   PASS  remote stops driving the link, and a keypress still reconnects/wakes it
#   FAIL  nothing changes, or the remote will not come back
set -u
MAC=${1:-74:CC:23:DE:9D:33}
U=00002a4c-0000-1000-8000-00805f9b34fb

bluetoothctl info "$MAC" 2>/dev/null | grep -q "Connected: yes" || {
	echo "remote not connected — press a key first"; exit 1; }

# bluetoothctl indents object paths with a tab, so anchor on the path itself
PATHS=$(bluetoothctl gatt.list-attributes "$MAC" 2>/dev/null |
	awk -v u="$U" '/\/org\/bluez\// { p = $1 } index($0, u) && p { print p; p = "" }')
[ -n "$PATHS" ] || { echo "FAIL: no HID Control Point exposed (0x2A4C absent)"; exit 1; }
echo "control point: $PATHS"

echo "HID_CP_TEST write 0x00" > /dev/kmsg
for p in $PATHS; do
	bluetoothctl <<-EOF | grep -iE "attribute|write|fail|error" | head -4
		gatt.select-attribute $p
		gatt.write 0x00
	EOF
done

echo "--- watching 60 s: link state and traffic ---"
for i in 1 2 3 4 5 6; do
	sleep 10
	printf "  +%02ds  %s  acl=%s\n" "$((i * 10))" \
		"$(bluetoothctl info "$MAC" 2>/dev/null | grep Connected | tr -d '\t')" \
		"$(hciconfig hci0 | grep -oE 'acl:[0-9]*' | head -1)"
done

echo "--- now press a remote key; 30 s to see whether it still wakes/reconnects ---"
for i in 1 2 3; do
	sleep 10
	printf "  +%02ds  %s\n" "$((i * 10))" \
		"$(bluetoothctl info "$MAC" 2>/dev/null | grep Connected | tr -d '\t')"
done

echo "--- restoring: 0x01 exit suspend ---"
for p in $PATHS; do
	bluetoothctl >/dev/null 2>&1 <<-EOF
		gatt.select-attribute $p
		gatt.write 0x01
	EOF
done
echo "HID_CP_TEST done"
