#!/bin/bash
#
# ln -s --relative . ~/autostart/usb-fix
# see https://github.com/hilbix/ptybuffer/blob/master/script/autostart.sh
#
# Execute this each 5 minutes or so

ME="$(readlink -e -- "$0")" &&
WORK="$(readlink -e -- "${ME%/*/*}")" &&
while	"$WORK/usb-fix.sh"
	printf '%(%Y%m%d-%H%M%S)T ' && ! read -t 500 && printf '%(%Y%m%d-%H%M%S)T\n'
do :; done

