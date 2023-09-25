#!/bin/bash
#
# vim: ft=bash
#
# Reactivate USB devices which became offline
# due to USB disconnects which failed to revive the device for unknown reason.
#
# For following to work you must use following setup:
#
# - Make the complete device a PV (pvcreate /dev/sdX)
# - Put the PV into its own unique VG zfsN (vgcreate zfsN /dev/sdX)
# - create the ARC as LV on the VG arcN (lvcreate -L90% -n arcN zfsN)
# - attach the LV to ZFS as ARC (zpool add zfs cache /dev/zfsN/arcN)
# - this is very easy to grok and maintain!
#
# I think this is due to a combined hardware + software effort:
#
# - The USB hardware is unreliable (bit errors?) either on mainboard or on device
# - The Linux USB-driver is unable to reset the bus properly for some reason
# - The devices becomes offlined
#
# Then following needs to be done:
#
# - Offline device on ZFS, so the device becomes free
# - reset the USB device (using USB deactivating sequence)
# - revive the VG
# - online the device on ZFS
#
# I DO NOT RECOMMEND TO RUN THIS HERE FOR OTHER TYPE OF DEVICES
# which need resilvering.  However it might work to revice USB mirrors this way.
#
# Rationale:
#
# I attach several NVMe ZFS ARC devices via USB-C 3.2 (10 Gbit/s).
# These flash devices usually wear out fast, so there must be a way to easily replace them.
#
# However, for unknown reason, the USB hardware offlines the devices now and then.
# As this only affects ARCs this is not problematic at all
# and the revive process (done by this script) causes no interruption.
#
# Note that the ARC does not lose its content.  Hence after revive it continues to work.
# Also note that you can add and remove ARC devices for different workloads without problem.
# So for example if you have a special nightly process which reads lots of data,
# you can online some ARC for this, run the job, and offline it afterwards.
# And with USB you can attach tons of such cheap devices
# (it is only $50 per TiB today).
# ZFS is very flexible in this respect.

POOL=zfs

export LC_ALL=C.UTF-8

STDOUT(){ printf %q "$1"; [ 1 -ge $# ] || printf ' %q' "${@:2}"; printf '\n'; }
STDERR(){ local e=$?; STDOUT "$@" >&2; return $e; }
CALLER() { local c="$(caller ${1:-0})" && [ -n "$c" ] || return; printf '#E#%q#%d#1#%s#\n' "$0" "${c%% *}" "${*:2}: ${c#* }"; CALLER $[$1+2] "${@:2}"; }
OOPS()	{ CALLER 1 OOPS "$@"; STDERR OOPS: "$@"; exit 23; }
x()	{ STDERR exec "$@"; "$@"; STDERR ret$? "$@"; }
o()	{ x "$@" || OOPS fail $? "$@"; }
v()	{ local -n ___VAR___="$1"; ___VAR___="$(x "${@:2}")"; }
ov()	{ o v "$@"; }

#zpool status -P

# example:
# revive /dev/sde /sys/devices/pci0000:00/0000:00:08.1/0000:11:00.3/usb6/6-1/6-1:1.0/host14/target14:0:0/14:0:0:0/block/sde
# $2 is not used
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
        o test ".$fullpath" = ".$2"

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
  STDERR = revivedev "$@"

  x zpool offline "$POOL" "/dev/mapper/$3"	# free it from ZFS

  ov usbpath readlink -e "$5/device/../../../.."
  auth="$usbpath/authorized"

  o test -f "$auth"

  echo 0 > "$auth"				# deactivate USB device
  sleep 1
  echo 1 > "$auth"				# reactivate USB device
  sleep 10

  # The device should be there again
  ov now cat "$usbpath/${usbpath##*/}":*/host*/target*/*/state
  case "$now" in
  (running)	;;
  (*)		OOPS "$usbpath" target state is "$now";;
  esac

  x dmsetup info "$3" &&			# Open Count must be 0 now (not checked)
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

# DOES NOT WORK reliably:
## Find USB devices
#DISKS=/dev/disk/by-id/usb
#for a in "${DISKS}"*
#do
#	v x readlink -e "$a" || continue
#	DEV["$x"]="$a"
##	echo + "$x"
#done

# This seems to work better
while read -ru6 a
do
        for b in "$a"/*
        do
                DEV["/dev/${b##*/}"]="$a/${b##*/}"
        done
done 6< <(find /sys/bus/usb/devices/*/. -name block -type d | while read a; do o readlink -e "$a"; done | sort -u)

# Ignore USB devices which are properly used in LVM
# THIS PROBABLY IS NOT NEEDED as revive() checks for USB status, too
while read -ru6 a
do
#        echo - "$a"
        unset DEV["$a"]
done 6< <(o pvs --reportformat json | jq -r '.report[].pv[].pv_name')

# Revive all missing USB devices
for a in "${!DEV[@]}" 
do
#        printf '%q %q\n' "$a" "${DEV["$a"]}"
        revive "$a" "${DEV["$a"]}"
done

