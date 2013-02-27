#!/bin/ash

# Author:	william2003[at]gmail[dot]com
#			duonglt[at]engr[dot]ucsb[dot]edu
#			kernelsmith[at]kernelsmith[dot]com
# Date: 01/10/2011
#
# Custom Shell script to clone Virtual Machines for Labs at UCSB and JHUAPL
# script takes a number of agruments based on a golden image along with
# designated virtual machine lab name and a range of VMs to be created.
#############################################################################################

ESXI_VMWARE_VIM_CMD=/bin/vim-cmd
CREATE_FIREWALL_RULES="true"
#DEVEL_MODE=1
DEBUG=""

#
# ERROR CODES
#
ERR_NO_VIM_CMD=200
ERR_MASTER_VM_BAD=201
ERR_MASTER_VM_ONLINE_NOT_REG=202
ERR_MASTER_VM_SNAP_RAW=203
ERR_MASTER_VM_BAD_ETH0=204
ERR_MASTER_VM_EXCESS_VMDKS=205
ERR_START_VAL_INVALID=210
ERR_STOP_VAL_INVALID=211
ERR_WRONG_NUM_ARGS=220
ERR_NOT_DATASTORE=250

#
# Functions
#

debug() {
	if [ -n "${DEVEL_MODE}" -o -n "${DEBUG}" ]; then echo "[debug] $1" 1>&2;fi
}

debug_var(){
	eval val='${'$1'}'
	debug "$1 is:$val"
}

resolve_datastore() {
	debug "resolve_datastore:  received arguments:$@"
	# $1 is expected to be something like [datastore1] with or without the sq brackets
	if ! (echo $1 | grep -q datastore)
	then
		echo "Cannot resolve $1 because it does not look like a datastore"
	else
		# cleanup the provided argument
		ds=`echo $1 | sed 's/\[//g' | sed 's/\]//g'` # get rid of sq brackets
		debug_var ds
		echo `${ESXI_VMWARE_VIM_CMD} hostsvc/datastore/info $ds | grep url | cut -d'"' -f2`
	fi
}

replace_datastore() {
	# $1 should be something like [datastore1]/path_to/my_vm
	debug "replace_datastore:  received arguments:$@"
	orig_path=$1
	debug_var orig_path
	if ! (echo $orig_path | grep -qe '\[datastore[0-9]\+\]')
	then
		echo "Cannot replace datastore reference in $orig_path because it does not look like [datastore1]"
	else
		first_half=`echo $orig_path | cut -d ']' -f 1` # becomes ~ [datastore1
		debug_var first_half
		second_half=`echo $orig_path | cut -d ']' -f 2 | sed 's/^ *//'` # becomes ~ /path_to/my_vm
		debug_var second_half
		# the sed above trims leading spaces only
		store=`resolve_datastore ${first_half}`
		debug_var store
		echo "${store}/${second_half}"
	fi
}

mkdir_if_not_exist() {
	if ! [ -d $1 ]; then mkdir -p $1;fi
}

package_vmx() {
	vmx=$1
	debug "Packaging vmx file:$vmx"
	if [ -n "$2" ];then
		# a vnc port was provided, let's use it and use a hardcoded password for now
		# NOTE:  You may need to adjust the esxi firewall (for certain versions of esxi)
		#		To do so, checkout the here document at the end of this script
		vnc_port=$2
		vnc_pass="lab"
		# Remove all vnc related lines
		debug "Removing vnc references"
		sed -i '/RemoteDisplay.vnc.*/d' $vmx > /dev/null 2>&1
		# now add them back (except vnc.key) with our stuff
		debug "Adding new vnc references back in"
		echo "RemoteDisplay.vnc.enabled = \"true\"" >> $vmx
		echo "RemoteDisplay.vnc.port = \"$vnc_port\"" >> $vmx
		echo "RemoteDisplay.vnc.password = \"$vnc_pass\"" >> $vmx
	fi

	#
	# All the items below will get regenerated once the vm is booted for the first time
	#

	# Remove remnants of an autogenerated mac address
	debug "Removing mac address and uuid references"
	sed -i '/ethernet0.generatedAddress/d' $vmx > /dev/null 2>&1
	sed -i '/ethernet0.addressType/d' $vmx > /dev/null 2>&1
	sed -i '/uuid.location/d' $vmx > /dev/null 2>&1
	sed -i '/uuid.bios/d' $vmx > /dev/null 2>&1

	# Remove derived name
	debug "Removing derivedName"
	sed -i '/sched.swap.derivedName/d' $vmx > /dev/null 2>&1
}

printBanner() {
	echo "######################################################"
	echo "#"
	echo "# Linked Clones Tool for ESXi"
	echo "# Author: william2003[at]gmail[dot]com"
	echo -e "#\tduonglt[at]engr[dot]ucsb[dot]edu"
	echo -e "#\tkernelsmith[at]kernelsmith[dot]com"
	echo "# Created: 09/30/2008"
	echo "# Updated: 1/10/2011"
	echo "######################################################"
}

validateUserInput() {
	#sanity check to make sure you're executing on an ESX 3.x host
	if [ ! -f ${ESXI_VMWARE_VIM_CMD} ]
	then
		echo "This script is meant to be executed on VMware ESXi, please try again ...."
		exit $ERR_NO_VIM_CMD
	fi
	debug "ESX Version valid (3.x+)"

	if ! (echo ${GOLDEN_VM} | egrep -i '[0-9A-Za-z]+.vmx$' > /dev/null) && [[ ! -f "${GOLDEN_VM}" ]]
	then
		echo "Error: Golden VM Input is not valid"
		exit $ERR_MASTER_VM_BAD
	fi

	if [ "${DEVEL_MODE}" -eq 1 ]; then
		echo -e "\n############# SANITY CHECK START #############\n\nGolden VM vmx file exists"
	fi

	#
	# sanity check to verify Golden VM is offline before duplicating
	#
	${ESXI_VMWARE_VIM_CMD} vmsvc/get.runtime ${GOLDEN_VM_VMID} | grep -i "powerState" | \
		grep -i "poweredOff" > /dev/null 2>&1
	if [ ! $? -eq 0 ]; then
		echo "Master VM status is currently online, not registered or does not exist, please try again..."
		exit $ERR_MASTER_VM_ONLINE_NOT_REG
	fi

	debug "Golden VM is offline"
	local mastervm_dir=$(dirname "${GOLDEN_VM}")

	if (ls "${mastervm_dir}" | grep -iE '(delta|-rdm.vmdk|-rdmp.vmdk)' > /dev/null 2>&1)
	then
		echo "Master VM contains either a Snapshot or Raw Device Mapping, please ensure those " \
			"are gone and please try again..."
		exit $ERR_MASTER_VM_SNAP_RAW
	fi
	debug "Snapshots and RDMs were not found"

	if ! (grep -i "ethernet0.present = \"true\"" "${GOLDEN_VM}" > /dev/null 2>&1)
	then
		echo "Master VM does not contain valid eth0 vnic, script requires eth0 to be present "\
			"and valid, please try again..."
        exit $ERR_MASTER_VM_BAD_ETH0
	fi
	debug "eth0 found and is valid"

	vmdks_count=`grep -i scsi "${GOLDEN_VM}" | grep -i fileName | awk -F "\"" '{print $2}' | wc -l`
	vmdks=`grep -i scsi "${GOLDEN_VM}" | grep -i fileName | awk -F "\"" '{print $2}'`
	if [ "${vmdks_count}" -gt 1 ]
	then
		echo "Found more than 1 VMDK associated with the Master VM, script only supports a "\
			"single VMDK, please unattach the others and try again..."
		exit $ERR_MASTER_VM_EXCESS_VMDKS
	fi

	debug "Single VMDK disk found"

	if ! (echo ${START_COUNT} | egrep '^[0-9]+$' > /dev/null)
	then
		echo "Error: START value is not valid"
		exit $ERR_START_VAL_INVALID
	fi
	debug "START parameter is valid"

	if ! (echo ${END_COUNT} | egrep '^[0-9]+$' > /dev/null)
	then
		echo "Error: END value is not valid"
		exit $ERR_STOP_VAL_INVALID
	fi
	debug "END parameter is valid"

	# sanity check to verify your range is positive
	if [ "${START_COUNT}" -gt "${END_COUNT}" ]
	then
		echo "Your Start Count can not be greater or equal to your End Count, please try again..."
		exit $ERR_START_VAL_INVALID
	fi
	debug "START and END range is valid"

	#
	# end of sanity check
	#
	if [ "${DEVEL_MODE}" -eq 1 ]
	then
		echo -e "\n########### SANITY CHECK COMPLETE ############\n" && exit 0
	fi
}

#
# START
#

# sanity check on the # of args
if [ $# -ne 5 ]
then

	printBanner
	echo -e "\nUsage: `basename $0` [FULL_PATH_TO_MASTER_VMX_FILE]
[VM_NAME] [START_#] [END_#] [POWER_OFF?]"
	echo -e "i.e."
	echo -e "  $0 [datastore1]/LabMaster/LabMaster.vmx LabClient- 1 20 true"
	echo -e "Output:"
	echo -e "  LabClient-{1-20}"
	echo -e "VM_NAME assumed to be relative to datastore containing the master vmx"
	exit $ERR_WRONG_NUM_ARGS
fi

#
# INTERNAL VARIABLES, DO NOT TOUCH UNLESS YOU ARE BASHY
#

# set variables

# get the fullly resolved (no symlinks) absolute path to the vmx file passed into the script
# even accept [datastore1] type references if given as [datastore1] /path/vmx
GOLDEN_VM="$1"
# basic sanity check on the vm (vmx) file
if ! echo $GOLDEN_VM | grep -qe '\.vmx'
then
	echo "The provided vm doesn't appear to be a vmx file"
	exit $ERR_MASTER_VM_BAD
fi
debug_var GOLDEN_VM
if (echo $GOLDEN_VM | grep -qe '^\[datastore[0-9]\+\]');then
	# found a datastore (starts with [datastore1] or [datastore2] etc)
	echo "[*]  Resolving datastore reference $GOLDEN_VM"
	temp_path="`replace_datastore "$GOLDEN_VM"`"
	debug_var temp_path
	GOLDEN_VM=`/bin/readlink -f $temp_path`
else
	# no datastore reference, so just fully deref the given path
	GOLDEN_VM=`/bin/readlink -f $1`
fi
debug_var GOLDEN_VM
VM_NAMING_CONVENTION=$2
debug_var VM_NAMING_CONVENTION
START_COUNT=$3
debug_var START_COUNT
END_COUNT=$4
debug_var END_COUNT
POWER_OFF=''
if echo "$5" | grep -q -i true; then POWER_OFF="TRUE";fi
debug_var POWER_OFF

# get path to vmx w/o the "vmx"
GOLDEN_VM_PATH=`echo ${GOLDEN_VM%%.vmx*}`
debug_var GOLDEN_VM_PATH
# get the golden vm's name
GOLDEN_VM_NAME=`grep -i "displayName" ${GOLDEN_VM} | awk '{print $3}' | sed 's/"//g'`
debug_var GOLDEN_VM_NAME
# get the golden vm's vmid
GOLDEN_VM_VMID=`${ESXI_VMWARE_VIM_CMD} vmsvc/getallvms | grep -i ${GOLDEN_VM_NAME} | awk '{print $1}'`
debug_var GOLDEN_VM_VMID
# get the part of the path relative to the datastore
TO_REMOVE=`${ESXI_VMWARE_VIM_CMD} vmsvc/get.config $GOLDEN_VM_VMID|grep vmPathName|awk '{print $4}'|sed 's/",//g'`
# now get the base part of the path (which is probably just the real path to the datastore)
STORAGE_PATH=`echo ${GOLDEN_VM%$TO_REMOVE*}`
debug_var STORAGE_PATH

validateUserInput

# print out user configuration - requires user input to verify the configs before duplication
# read in busybox/ash sucks so we use this loop instead
while true;
do
	echo -e "Requested parameters:"
	echo -e "  - Master Virtual Machine Image: $GOLDEN_VM"
	echo -e "  - Linked Clones output: $VM_NAMING_CONVENTION{$START_COUNT-$END_COUNT}"
	echo
	echo "Would you like to continue with this configuration y/n?"
	read userConfirm
	case $userConfirm in
		yes|YES|y|Y)
			echo "Cloning will proceed for $VM_NAMING_CONVENTION{$START_COUNT-$END_COUNT}"
			echo
			break;;
		*)
			echo "Requested parameters canceled, application exiting"
			exit;;
	esac
done

#
# start duplication
#
COUNT=$START_COUNT
MAX=$END_COUNT
START_TIME=`date`
S_TIME=`date +%s`
TOTAL_VM_CREATE=$(( ${END_COUNT} - ${START_COUNT} + 1 ))

LC_EXECUTION_DIR=/tmp/esxi_linked_clones_run.$$
mkdir_if_not_exist "${LC_EXECUTION_DIR}"
LC_CREATED_VMS=${LC_EXECUTION_DIR}/newly_created_vms.$$
touch ${LC_CREATED_VMS}

WATCH_FILE=${LC_CREATED_VMS}
EXPECTED_LINES=${TOTAL_VM_CREATE}
all_vmids=''
echo;echo;echo;echo;echo "-----------------------------------------------------------------"
while sleep 5;
do
	REAL_LINES=$(wc -l < "${WATCH_FILE}")
	REAL_LINES=`echo ${REAL_LINES} | sed 's/^[ \t]*//;s/[ \t]*$//'`
	P_RATIO=$(( (${REAL_LINES} * 100 ) / ${EXPECTED_LINES} ))
	P_RATIO=${P_RATIO%%.*}
	echo -en "\r${P_RATIO}% Complete! - Linked Clones Created:  ${REAL_LINES}/${EXPECTED_LINES}"
	if [ ${REAL_LINES} -ge ${EXPECTED_LINES} ]; then break; fi
done &

while [ "$COUNT" -le "$MAX" ];
do
	debug "*** $COUNT ***"
	# create final vm name
	FINAL_VM_NAME="${VM_NAMING_CONVENTION}${COUNT}"
	debug_var FINAL_VM_NAME
	FINAL_VM_VNC_PORT=$(( 6000 + $COUNT )) # so if this is vm count 7, vncviewer esxihost::6007
	debug_var FINAL_VM_VNC_PORT
	# make new directory for new vm
	mkdir_if_not_exist "${STORAGE_PATH}/$FINAL_VM_NAME"
	FINAL_VMX_PATH=${STORAGE_PATH}/$FINAL_VM_NAME/$FINAL_VM_NAME.vmx
	debug_var FINAL_VMX_PATH
	# copy the original vmx there and name it after the final vm name
	cp ${GOLDEN_VM_PATH}.vmx $FINAL_VMX_PATH
	# the original vmdk's path in the config file might be relative or absolute so we
	# get it from vim-cmd instead of from the config file cuz we prefer absolute for esxi 4+
	ORIG_VMDK_PATH=`$ESXI_VMWARE_VIM_CMD vmsvc/get.filelayout $GOLDEN_VM_VMID | grep -A 1 diskFile | tail -n 1`
	ORIG_VMDK_PATH="`echo $ORIG_VMDK_PATH | cut -d '"' -f2`"
	debug_var ORIG_VMDK_PATH
	# vmdk path probably needs a datastore resolution
	if (echo $ORIG_VMDK_PATH | grep -q datastore)
	then
		VMDK_PATH=`replace_datastore "$ORIG_VMDK_PATH"`
	else
		VMDK_PATH=$ORIG_VMDK_PATH
	fi
	debug_var VMDK_PATH
	# replace old display name with the new one
	sed -i 's/displayName = "'${GOLDEN_VM_NAME}'"/displayName ="'${FINAL_VM_NAME}'"/' $FINAL_VMX_PATH
	# delete original vmdk line
	sed -i '/scsi0:0.fileName/d' $FINAL_VMX_PATH
	# add the repaired vmdk line back in (absolute path to vmkd)
	echo "scsi0:0.fileName = \"${VMDK_PATH}\"" >> $FINAL_VMX_PATH
	# replace nvram reference
	sed -i 's/nvram = "'${GOLDEN_VM_NAME}.nvram'"/nvram ="'${FINAL_VM_NAME}.nvram'"/' $FINAL_VMX_PATH
	# replace the extendedConfigFile reference
	sed -i 's/extendedConfigFile ="'${GOLDEN_VM_NAME}.vmxf'"/extendedConfigFile ="'${FINAL_VM_NAME}.vmxf'"/' \
		$FINAL_VMX_PATH
	# package the vmx so vmware/esxi won't think it previously existed
	package_vmx $FINAL_VMX_PATH $FINAL_VM_VNC_PORT
	# register the new vm with esxi so it knows about it
	debug "Registering $FINAL_VMX_PATH"
	${ESXI_VMWARE_VIM_CMD} solo/registervm $FINAL_VMX_PATH > /dev/null 2>&1
	# get the new vms vmid
	FINAL_VM_VMID=`${ESXI_VMWARE_VIM_CMD} vmsvc/getallvms | grep -i ${FINAL_VM_NAME} | awk '{print $1}'`
	debug_var FINAL_VM_VMID
	# Create a snapshot, this actually creates the linked clone's delta vmdk'?
	debug "Creating snapshot for ${FINAL_VM_VMID}"
	${ESXI_VMWARE_VIM_CMD} vmsvc/snapshot.create ${FINAL_VM_VMID} \
		Cloned ${FINAL_VM_NAME}_Cloned_from_${GOLDEN_VM_NAME} > /dev/null 2>&1

	# output to file to later use
	echo "$FINAL_VMX_PATH" >> "${LC_CREATED_VMS}"
	# collect all the vmids in case user wants us to shut them down
	all_vmids="${all_vmids}${FINAL_VM_VMID} "

	# start the vm so it will get a new mac etc
	echo "[*] Starting VM:  ${FINAL_VM_VMID}"
	${ESXI_VMWARE_VIM_CMD} vmsvc/power.on ${FINAL_VM_VMID}

	COUNT=$(( $COUNT + 1 ))
done

END_TIME=`date`
E_TIME=`date +%s`

# This here document will create a rule in the firewall to allow vnc for the linked clones
# it allows inbound on 6000 thru 6500 to accomodate up to 501 linked clones
rule=/etc/vmware/firewall/vnc_for_linked_clones.xml
# if CREATE_FIREWALL_RULES is true, and the rules dir exists, and this rule doesn't exist
if ([ -n "$CREATE_FIREWALL_RULES" ] && [ -d /etc/vmware/firewall/ ] && ! [ -f $rule ])
then
echo "Creating Firewall Rules for VNC"
cat <<__EOF__ > $rule
 <!-- Firewall configuration information for VNC LINKED CLONES -->
  <ConfigRoot>
  	<service>
  		<id>VNC_LINKED_CLONES</id>
  		<rule id='0000'>
  			<direction>inbound</direction>
  			<protocol>tcp</protocol>
  			<porttype>dst</porttype>
  			<port>
  				<begin>6000</begin>
  				<end>6500</end>
  			</port>
  		</rule>
  		<rule id='0001'>
  			<direction>outbound</direction>
  			<protocol>tcp</protocol>
  			<porttype>dst</porttype>
  			<port>
  				<begin>0</begin>
  				<end>65535</end>
  			</port>
  		</rule>
  		<enabled>true</enabled>
  		<required>false</required>
 	</service>
 </ConfigRoot>
__EOF__

	# refresh the firewall ruleset
	echo "Refreshing the firewall ruleset"
	/sbin/esxcli network firewall refresh
	debug "VNC firewall rule active? " "`/sbin/esxcli network firewall ruleset list | grep VNC_LINKED_CLONES`"
fi

sleep 10
echo -e "\n\nWaiting for Virtual Machine(s) to startup and obtain MAC addresses...\n"

#grab mac addresses of newly created VMs (file to populate dhcp static config etc)
if [ -f ${LC_CREATED_VMS} ]
then
	for i in `cat ${LC_CREATED_VMS}`
	do
		TMP_LIST=${LC_EXECUTION_DIR}/vm_list.$$
		VM_P=`echo ${i##*/}`
		VM_NAME=`echo ${VM_P%.vmx*}`
		VM_MAC=`grep -i ethernet0.generatedAddress "${i}"|awk '{print $3}'|sed 's/\"//g'|head -1|sed 's/://g'`
		while [ "${VM_MAC}" == "" ]
		do
			sleep 1
			VM_MAC=`grep -i ethernet0.generatedAddress "${i}"|awk '{print $3}'|sed 's/\"//g'|head -1|sed 's/://g'`
		done
		echo "${VM_NAME}  ${VM_MAC}" >> ${TMP_LIST}
	done
	LCS_OUTPUT="lcs_created_on-`date +%F-%H%M%S`"
	echo -e "Linked clones VM MAC addresses stored at:"
	cat ${TMP_LIST} | sed 's/[[:digit:]]/ &/1' | sort -k2n | sed 's/ //1' > "${LCS_OUTPUT}"
	echo -e "\t${LCS_OUTPUT}"
fi

echo
echo "Start time: ${START_TIME}"
echo "End   time: ${END_TIME}"
DURATION=`echo $((E_TIME - S_TIME))`

#calculate overall completion time
if [ ${DURATION} -le 60 ]
then
	echo "Duration  : ${DURATION} Seconds"
else
	echo "Duration  : `awk 'BEGIN{ printf "%.2f\n", '${DURATION}'/60}'` Minutes"
fi
echo
rm -rf ${LC_EXECUTION_DIR}

# power off the vms if requested
if ([ -n "$POWER_OFF" ] && [ -n "$all_vmids" ])
then
	echo "[*] Powering off VMs"
	for id in $all_vmids; do debug_var "id" && $ESXI_VMWARE_VIM_CMD vmsvc/power.off $id; done
fi

