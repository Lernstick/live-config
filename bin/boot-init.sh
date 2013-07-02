#!/bin/sh

## live-config(7) - System Configuration Scripts
## Copyright (C) 2006-2013 Daniel Baumann <daniel@debian.org>
##
## This program comes with ABSOLUTELY NO WARRANTY; for details see COPYING.
## This is free software, and you are welcome to redistribute it
## under certain conditions; see COPYING for details.


set -e

# Exit if system is not a live system
if ! grep -qs "boot=live" /proc/cmdline || \
# Exit if system is netboot
   grep -qs "netboot" /proc/cmdline || \
   grep -qs "root=/dev/nfs" /proc/cmdline || \
   grep -qs "root=/dev/cifs" /proc/cmdline || \
# Exit if system is toram
   grep -qs "toram" /proc/cmdline
then
	exit 0
fi



# Try to cache everything we're likely to need after ejecting. This
# is fragile and simple-minded, but our options are limited.
cache_path()
{
	path="${1}"

	if [ -d "${path}" ]
	then
		find "${path}" -type f | xargs cat > /dev/null 2>&1
	elif [ -f "${path}" ]
	then
		if file -L "${path}" | grep -q 'dynamically linked'
		then
			# ldd output can be of three forms:
			# 1. linux-vdso.so.1 =>  (0x00007fffe3fb4000)
			#    This is a virtual, kernel shared library and we want to skip it
			# 2. libc.so.6 => /lib/libc.so.6 (0x00007f5e9dc0c000)
			#    We want to cache the third word.
			# 3. /lib64/ld-linux-x86-64.so.2 (0x00007f5e9df8b000)
			#    We want to cache the first word.
			ldd "${path}" | while read line
			do
				if echo "$line" | grep -qs ' =>  '
				then
					continue
				elif echo "$line" | grep -qs ' => '
				then
					lib=$(echo "${line}" | awk '{ print $3 }')
				else
					lib=$(echo "${line}" | awk '{ print $1 }')
				fi
				cache_path "${lib}"
			done
		fi

		cat "${path}" >/dev/null 2>&1
	fi
}

get_boot_device()
{
	# search in /proc/mounts for the device that is mounted at /lib/live/mount/medium
	while read DEVICE MOUNT REST
	do
		case "${MOUNT}" in
			/lib/live/mount/medium)
				echo "${DEVICE}"
				exit 0
				;;
		esac
	done < /proc/mounts
}

device_is_USB_flash_drive()
{
	# get unpartitioned device name by extracting all alphanumerical 
	# characters from the start of the string
	DEVICE=$(expr match ${1} "\([[:alpha:]]*\)")

	# check that the device is an USB device
	if readlink /sys/block/${DEVICE} | grep -q usb
	then
		return 0
	fi

	return 1
}

Eject ()
{
	BOOT_DEVICE="$(basename $(get_boot_device))"
	if grep -qs "eject_request" /sys/block/${BOOT_DEVICE}/events
	then
		# device is ejectable, USB flash drives don't support eject_request events
		# ejecting is a very good idea here
		MESSAGE="$(gettext "Please remove the disc, close the tray (if any) and")"

		if [ -x /usr/bin/eject ]
		then
			# dialog (below) needs a working system, therefore we
			# wait for a second before calling eject. Caching is not
			# enough as dialog creates sockets and pipes.
			(sleep 1; eject -p -m /lib/live/mount/medium >/dev/null 2>&1) &
		fi

		if [ "${NOPROMPT}" = "cd" ]
		then
			prompt=
		fi
	elif device_is_USB_flash_drive ${BOOT_DEVICE}
	then
		# do NOT eject USB flash drives!
		# otherwise rebooting with most USB flash drives
		# fails because they actually remember the
		# "ejected" state even after reboot
		MESSAGE="$(gettext "Please remove the USB flash drive and")"

		if [ "${NOPROMPT}" = "usb" ]
		then
			prompt=
		fi
	
	else
		# device is NOT removable, probably an internal hard drive
		# there is no need to wait or show any dialog here
		return 0
	fi

	[ "$prompt" ] || return 0

	# determine current action (do we shutdown or reboot?)
	# this info is used later for the messages prompted to the user
	if [ "${RUNLEVEL}" = "0" ]
	then
		TITLE="$(gettext "Shutdown")"
		OK_LABEL="$(gettext "Shut Down")"
		### TRANSLATORS: these are the shutdown ${INFINITIVE} and ${FUTURE} used later 
		### Plural[0]=Infinitive I, Plural[1]=Futur I
		INFINITIVE="$(ngettext "shut down" "shut down" 1)"
		FUTURE="$(ngettext "shut down" "shut down" 2)"
	elif [ "${RUNLEVEL}" = "6" ]
	then
		TITLE="$(gettext "Reboot")"
		OK_LABEL="$(gettext "Reboot")"
		### TRANSLATORS: this is the reboot ${INFINITIVE} used later 
		INFINITIVE="$(gettext "reboot")"
		### TRANSLATORS: this is the reboot ${FUTURE} used later 
		FUTURE="$(gettext "rebooted")"
	else
		log_warning_msg "Unsupported runlevel!"
	fi
	PRESS_ENTER="$(eval_gettext "press ENTER to \${INFINITIVE} the system")"
	
#	if [ -x /bin/plymouth ] && plymouth --ping
#	then
#		plymouth message --text="${MESSAGE} ${PRESS_ENTER}."
#		plymouth watch-keystroke > /dev/null
#	elif [ -x /usr/bin/dialog ]
        if [ -x /usr/bin/dialog ]
	then
		# show message via dialog
		MESSAGE="$(eval_gettext "\${MESSAGE} \${PRESS_ENTER}.\n\n(If you do nothing, the system will be automatically \${FUTURE} when the timer runs out.)")"
		# gdm messes with the virtual terminals
		# therefore we have to enforce the usage of vt1 here with chvt and openvt
		if [ -x /bin/chvt -a -x /bin/openvt ]
		then
			chvt 1
			openvt -c 1 -f -w -- dialog --nocancel --backtitle "${TITLE}" --ok-label "${OK_LABEL}" --pause "${MESSAGE}" 16 45 15
		else
			dialog --nocancel --backtitle "${TITLE}" --ok-label "${OK_LABEL}" --pause "${MESSAGE}" 16 45 15
		fi
	else
		# show message via console
		stty sane < /dev/console
		printf "\n\n${MESSAGE}\n${PRESS_ENTER}:" > /dev/console
		read x < /dev/console
	fi
}

# Hey! Who the hell took away our locale settings?
# Let's get it back now...
if [ -f /etc/default/locale ]
then
	. /etc/default/locale
	export LC_ALL=${LANG}
fi

# gettext support
. /etc/default/locale

if [ -r /usr/bin/gettext.sh ]
then
	. gettext.sh
else
	gettext () {
		echo "$1"
	}
	eval_gettext () {
		eval "echo $1"
	}
fi

export TEXTDOMAIN=live-boot

echo "live-boot: caching reboot files..."

prompt=1

case "${NOPROMPT}" in
	yes)
		prompt=
		;;
esac

for path in $(which halt) $(which reboot) /etc/rc?.d /etc/default $(which stty) /bin/plymouth
do
	cache_path "${path}"
done

mount -o remount,ro /lib/live/mount/overlay > /dev/null 2>&1

# Remounting any persistence devices read-only
for _MOUNT in $(awk '/\/lib\/live\/mount\/persistence/ { print $2 }' /proc/mounts)
do
	mount -o remount,ro ${_MOUNT} > /dev/null 2>&1
done

# Flush filesystem buffers
sync

# Check if we need to eject the drive
if grep -qs "cdrom-detect/eject=false" /proc/cmdline || \
   grep -qs "noeject" /proc/cmdline || \
   grep -qs "find_iso" /proc/cmdline
then
	return
else
	Eject
fi
