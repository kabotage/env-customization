#!/bin/bash

usage() {
	echo "USAGE: `basename $0` vmx_file [[vnc_port]|[mac_addy]]"
	echo
	echo -e "Packages the vmx_file for distibution or cloning etc.  Optionally a mac_addy or"
	echo -e "vnc_port or both can be given to assign a static mac address and/or enable vnc on"
	echo -e "the provided port.  The order of args after vmx_file is inconsequential"
	echo
	echo "EXAMPLE:"
	echo "  $0 /my/coolVM.vmx 5901 00:50:56:XX:YY:ZZ"
	# Args 2 & 3 are differentiated by a crappy but effective regex and can be given in any order
	# Mac addy should be given in the format shown above (with :)
}

package_vmx() {
	vmx=$1
	# give usage if requested or needed
	if [ $vmx == "-h" ]; then usage && exit 0;done
	# should be 1 to 3 args
	if [ $# > 3 ]; then usage && exit 3;done
	if [ $# < 1 ]; then usage && exit 1;done

	echo "Packaging vmx file:$vmx"
	echo "Removing mac address and uuid references"
	remove_autogen_mac $vmx

	# if more than one argument given
	if [ $# > 1 ]
		# this is a ghetto regex for mac addy but it will work fine and allows ':'s
		if [ echo "$2" | grep -qe '[:0-9A-Fa-f]\{12\}' ];then
			# then a mac address was given as the 2nd arg
			echo "Assigning the provided mac address"
			add_mac "$vmx"  "$2"
			if [ echo "$3" | grep -qe '[0-9]{1,5}' ]; then
				# then a vnc port was given too
				echo "Enabling VNC on port $3"
				add_vnc $1 $3
			fi
		else
			if [ echo "$2" | grep -qe '[0-9]{1,5}' ];then
				# then a vnc port was given as the 2nd arg
				echo "Enabling VNC on port $2"
				add_vnc $1 $2
				if [ echo "$3" | grep -qe '[:0-9A-Fa-f]\{12\}' ]; then
					# then a mac address was given too
					echo "Assigning the provided mac address"
					add_mac "$vmx"  "$3"
				fi
			fi
		fi
	fi

	#
	# These items will get regenerated once the vm is booted for the first time
	#
	# Remove derived name
	echo "Removing derivedName"
	sed -i '/sched.swap.derivedName/d' $vmx > /dev/null 2>&1
}

remove_autogen_mac() {
	# $1 is the vmx file to edit
	# Remove remnants of an autogenerated mac address
	thevmx="$1"
	sed -i '/ethernet0.generatedAddress/d' $thevmx > /dev/null 2>&1
	sed -i '/ethernet0.addressType/d' $thevmx > /dev/null 2>&1
	sed -i '/uuid.location/d' $thevmx > /dev/null 2>&1
	sed -i '/uuid.bios/d' $thevmx > /dev/null 2>&1
}

add_mac() {
	# the vmx file is $1, the mac addy is $2
	thevmx="$1"
	mac_addy="$2"
	# format = ethernet[n].address = 00:50:56:XX:YY:ZZ
	echo "ethernet0.address = $mac_addy" >> $thevmx
}

add_vnc() {
	# the vmx file is $1, the vnc port is $2
	# a vnc port was provided, let's use it and use a hardcoded password for now
	# NOTE:  You may need to adjust the esxi firewall (for certain versions of esxi)
	thevmx="$1"
	vnc_port="$2"
	VNC_PASS="lab"
	# Remove all vnc related lines
	echo "Removing vnc references"
	sed -i '/RemoteDisplay.vnc.*/d' $thevmx > /dev/null 2>&1
	# now add them back (except vnc.key) with our stuff
	echo "Adding new vnc references back in"
	echo "RemoteDisplay.vnc.enabled = \"true\"" >> $thevmx
	echo "RemoteDisplay.vnc.port = \"$vnc_port\"" >> $thevmx
	echo "RemoteDisplay.vnc.password = \"$VNC_PASS\"" >> $thevmx
}

package_vmx "$@"
echo "Done."
