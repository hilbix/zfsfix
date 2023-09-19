#!/bin/bash
#
# vim: ft=bash
#
# Reactivate USB devices which became offline
# due to spurious (unnecessary) USB disconnects
#
# In that case the device vanishes completely
# in the kernel but not in UDEV
#
# I think this is a combined hardware + software error:
#
# - The USB hardware is unreliable either on mainboard or on device
# - The Linux USB-driver is unable to reset the bus properly for some reason
# - The devices becomes unavailable in kernel BUT NOT on udev
#
# What needs to be done:
#
# - Offline device on ZFS, so the device becomes free
# - reset the USB device

POOL=zfs
DISKS=/dev/disk/by-id/usb

STDOUT(){ printf %q "$1"; [ 1 -ge $# ] || printf ' %q' "${@:2}"; printf '\n'; }
STDERR(){ local e=$?; STDOUT "$@" >&2; return $e; }
CALLER() { local c="$(caller ${1:-0})" && [ -n "$c" ] || return; printf '#E#%q#%d#1#%s#\n' "$0" "${c%% *}" "${*:2}: ${c#* }"; CALLER $[$1+2] "${@:2}"; }
OOPS()	{ CALLER 1 OOPS "$@"; STDERR OOPS: "$@"; exit 23; }
x()	{ STDERR exec: "$@"; "$@"; STDERR ret$?: "$@"; }
o()	{ x "$@" || OOPS fail $?: "$@"; }
v()	{ local -n ___VAR___="$1"; ___VAR___="$(x "${@:2}")"; }
ov()	{ o v "$@"; }

#zpool status -P

revive()
{
  ov HEXMAJMIN stat --format '0x%t 0x%T' "$1"
  printf -v MAJMIN '%d:%d' $HEXMAJMIN
  STDERR : $MAJMIN

  # Find major:minor in /dev/mapper to offline it on zpool
  while read -ru6 dev offset cnt linear node devstart
  do
#	STDOUT "$dev" "$linear" "$node"
	[ linear = "$linear" ] || continue
	[ ".$MAJMIN" = ".$node" ] || continue
	name="${dev%:}"
	[ ".$name" != ".$dev" ] || continue

	ov fullpath readlink -e /sys/block/"${1#/dev/}"
	ov state cat "$fullpath/device/state"
	case "$state" in
	(running)	continue;;
	(offline)	;;
	(*)		OOPS unknown state of "$1": "$state";;
	esac
	revivevdev "$1" "$MAJMIN" "$name" "$state" "$fullpath"
  done 6< <(dmsetup table)
}

revivevdev()
{
  STDERR = revive "$@"

  x zpool offline "$POOL" "/dev/mapper/$3"	# free it from ZFS

  x dmsetup info "$3"				# Open Count must be 0 now

  ov usbpath readlink -e "$5/device/../../../.."
  auth="$usbpath/authorized"

  o test -f "$auth"

  echo 0 > "$auth"				# deactivate USB device
  sleep 1
  echo 1 > "$auth"				# reactivate USB device
  sleep 10

  # The device shoudl be there again
  ov now cat "$usbpath/${usbpath##*/}":*/host*/target*/*/state
  case "$now" in
  (running)	;;
  (*)		OOPS "$usbpath" target state is "$now";;
  esac

  o dmsetup remove "$3"				# remove old entry, fails if still in use

  vg="${3//--/\/}"
  vg="${vg%%-*}"
  vg="${vg//\//-}"
  o vgchange -ay "$vg"				# bing back LV

  o diskus -read -to 1G "/dev/mapper/$3"	# check LV really available again

  o zpool online "$POOL" "/dev/mapper/$3"	# online the device
  o zpool clear "$POOL" "/dev/mapper/$3"	# remove FAULTED state if any
}

declare -A DEV

# Find USB devices
for a in "${DISKS}"*
do
	v x readlink -e "$a" || continue
	DEV["$x"]="$a"
#	echo + "$x"
done

# Ignore USB devices which are properly used in LVM
while read -ru6 a
do
#	echo - "$a"
	unset DEV["$a"]
done 6< <(pvs --reportformat json | jq -r '.report[].pv[].pv_name')

# Revive all missing USB DEVs
for a in "${!DEV[@]}" 
do
	printf '%q %q\n' "$a" "${DEV["$a"]}"
	revive "$a"
done

