#!/bin/bash

# Lets get you orientated, top of the script is for variable asignments
# and such. We are not as strict as F77, ie. allowing loops for making
# lists but please refrain from defining variables that are non-implicit
# (like counters or tmps) outside of this area.

# All parts of the script that run as super user must be isolated at the
# bottem of the script inside of the debug if statement. Finaly, we are
# a fan of heredoc's (you should be too), so please use them.


configval() {
    cat $CONFIG_PATH | grep "$1" | awk '{d = "";
                            for (f=2; f<=NF; ++f)
                                {printf("%s%s", d, $f); d = OFS};
                                    printf("\n") }'
}

# Path variables
CONFIG_PATH=./dave.conf
TMP_EXPORT_CONF=./exports.tmp
TMP_NTP_CONF=./ntp.conf.tmp
TMP_DHCP_CONF=./dhcpcd.conf.tmp
TMP_HOSTS_CONF=./hosts.tmp
TMP_HOST_ALLOW_CONF=./hosts.allow.tmp
TMP_FSTAB_CONF=./fstab.tmp
TMP_SLURM_CONF=./slurm.conf.tmp
TMP_CGROUP_CONF=./cgroup.conf.tmp
TMP_CGROUP_ALLOWED_DEVICES_FILE=./cgroup-allowed-devices.conf.tmp

# Debug Variable
DEBUG=$(configval Debug)    # "Bool", string of "true" else false.


HOSTNAME_BASE=$(configval HostBase)   # String
NODE_COUNT=$(configval NodeCount)   # Intager

# IP Address Parsing
START_IP=$(configval StartIP)    # "String" (ip address)
START_SUBNET=$(("${START_IP##*.}"))    # example the 5 on 192.168.2.5
SUBNET=${START_IP%.*}'.'     # example 192.168.0.

# Generating Lists
NODE_NAME_LIST=()
IP_ADDR_LIST=()
for ((i = 0 ; i < NODE_COUNT ; i++)); do
    IP_ADDR_LIST+=("$SUBNET$((START_SUBNET+i))")
    NODE_NAME_LIST+=("$HOSTNAME_BASE$i")
done
read -r -a MASTER_INDEXES <<< "$(configval MasterIndexes)"
MASTER_IP_LIST=()
for INDEX in "${MASTER_INDEXES[@]}"; do
    MASTER_IP_LIST+=("$SUBNET$((START_SUBNET+INDEX))")
done
read -r -a DB_INDEXES <<< "$(configval DatabaseIndexes)"
DB_IP_LIST=()
for INDEX in "${DB_INDEXES[@]}"; do
    DB_IP_LIST+=("$SUBNET$((START_SUBNET+INDEX))")
done

NODE_ID=$1
if [ "$NODE_ID" == "" ]; then
    echo "No node id identified exiting"
    exit 1
fi
HOSTNAME=$HOSTNAME_BASE$NODE_ID

if [[ " ${MASTER_INDEXES[*]} " =~ [[:space:]]${NODE_ID}[[:space:]] ]];
then
    IS_MASTER="true"
else
    IS_MASTER="false"
fi

if [[ " ${DB_INDEXES[*]} " =~ [[:space:]]${NODE_ID}[[:space:]] ]];
then
    IS_DB="true"
else
    IS_DB="false"
fi


# Build /etc/hosts file
cat << EOF > $TMP_HOSTS_CONF
##########################################
#                                        #
# CONFIGURED BY DAVECL AUTOMATED SCRIPTS #
#                                        #
##########################################

127.0.0.1   localhost

::1     ip6-localhost ip6-loopback
fe00::0 ip6-localnet
ff00::0 ip6-mcastprefix
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters

# Master Nodes
$(i=0;
for IP in "${MASTER_IP_LIST[@]}"; do
    echo "$IP        master${i}"
    ((i++))
done)

# DB Nodes
$(i=0;
for IP in "${DB_IP_LIST[@]}"; do
    echo "$IP       database${i}"
    ((i++))
done)

# All Nodes
$(i=0;
for IP in "${IP_ADDR_LIST[@]}"; do
    echo "$IP       $HOSTNAME_BASE${i}"
    ((i++))
done)

EOF


# Build /etc/dhcpcd.conf
cat << EOF > $TMP_DHCP_CONF
##########################################
#                                        #
# CONFIGURED BY DAVECL AUTOMATED SCRIPTS #
#                                        #
##########################################

# Hostname
$HOSTNAME
option host_name

# Static IP Setup
profile node
static ip_address=${IP_ADDR_LIST[$NODE_ID]}
static routers=${SUBNET}1

interface eth0
fallback node

EOF


# Build /etc/ntp.conf
cat << EOF > $TMP_NTP_CONF
##########################################
#                                        #
# CONFIGURED BY DAVECL AUTOMATED SCRIPTS #
#                                        #
##########################################

$(if [ ${IS_MASTER} == "true" ]; then
    cat << EOOF
# Set local backup
server 127.127.1.0
fudge 127.127.1.0 stratum 10
# Host time
restrict ${SUBNET}0 mask 255.255.255.0 nomodify notrap
EOOF
fi)

$(for IP in "${MASTER_IP_LIST[@]}"; do
    echo "server ${IP} iburst"
done)
EOF


# Build /etc/fstab
awk '{if ($0 !~ /clusterfs/) {print $0}}' /etc/fstab > $TMP_FSTAB_CONF
if [ "${IS_DB}" == "true" ]; then
    UUID=$(blkid -s UUID -o value -t LABEL="/clusterfs")
    echo "UUID=${UUID} /clusterfs ext4 defaults 0 2" >> $TMP_FSTAB_CONF
else
    echo "${DB_IP_LIST[0]}:/clusterfs  /clusterfs  nfs  defaults  0  0" >> $TMP_FSTAB_CONF

fi


# Build /etc/exports && /etc/hosts.allow (DB ONLY)
if [ "$IS_DB" == "true" ]; then
    echo "/clusterfs    ${IP_ADDR_LIST[$NODE_ID]}:(rw,sync,no_root_squash,no_subtree_check)" > $TMP_EXPORT_CONF
    echo "ALL: ${NODE_NAME_LIST[*]}" > $TMP_HOST_ALLOW_CONF
fi


# Build /etc/slurm/slurm.conf
cat << EOF > $TMP_SLURM_CONF

ClusterName=$HOSTNAME_BASE
$(i=0;
for INDEX in "${MASTER_INDEXES[@]}"; do
    echo "SlurmctldHost=${NODE_NAME_LIST[$INDEX]}(${MASTER_IP_LIST[$i]})";
    ((i++))
done)


$(i=0;
for NODE in "${NODE_NAME_LIST[@]}"; do
    echo "NodeName=$NODE NodeAddr=${IP_ADDR_LIST[i]} CPUs=4 RealMemory=4096 State=UNKNOWN"
    ((i++))
done)

PartitionName=$HOSTNAME_BASE Nodes=ALL Default=YES MaxTime=INFINITE State=UP

SelectType=select/cons_tres
SelectTypeParameters=CR_Core_Memory

ProctrackType=proctrack/linuxproc
ReturnToService=2
SlurmctldPidFile=/run/slurmctld.pid
SlurmdPidFile=/run/slurmd.pid
SlurmdSpoolDir=/var/lib/slurm/slurmd
StateSaveLocation=/var/lib/slurm/slurmctld
SlurmUser=slurm
TaskPlugin=task/none
SchedulerType=sched/backfill
AccountingStorageType=accounting_storage/none
JobCompType=jobcomp/none
JobAcctGatherType=jobacct_gather/none
SlurmctldDebug=info
SlurmctldLogFile=/var/log/slurm/slurmctld.log
SlurmdDebug=info
SlurmdLogFile=/var/log/slurm/slurmd.log

EOF


# Build /etc/slurm/cgroup.conf
cat << EOF > $TMP_CGROUP_CONF
CgroupMountpoint="/sys/fs/cgroup"
CgroupAutomount=yes
CgroupReleaseAgentDir="/etc/slurm/cgroup"
AllowedDevicesFile="/etc/slurm/cgroup_allowed_devices_file.conf"
ConstrainCores=no
ConstrainRAMSpace=yes
ConstrainSwapSpace=no
ConstrainDevices=no
AllowedRamSpace=100
AllowedSwapSpace=0
MaxRAMPercent=100
MaxSwapPercent=100
MinRAMSpace=30
EOF


# Build /etc/slurm/cgroup_allowed_devices_file.conf
cat << EOF > $TMP_CGROUP_ALLOWED_DEVICES_FILE
/dev/null
/dev/urandom
/dev/zero
/dev/sda*
/dev/cpu/*/*
/dev/pts/*
/clusterfs*
EOF


# Debug/Real Run.
if [ "$DEBUG" == "true" ]; then

cat << EOF
HostBase: $HOSTNAME_BASE
HostName: $HOSTNAME

NodeList: ${NODE_NAME_LIST[*]}
IPList: ${IP_ADDR_LIST[*]}

MasterIndexes: ${MASTER_INDEXES[@]}
IPMaserList: ${MASTER_IP_LIST[*]}

DBIndexes: ${DB_INDEXES[@]}
IPDataBasesList:  ${DB_IP_LIST[@]}

EOF

else
    echo "DEBUG FALSE"
    sleep 2

    sudo apt install nfs-common ntp dhcpcd
    sudo systemctl enable nfs-common ntp ssh
    sudo systemctl start nfs-common ntp

    if [ "$IS_MASTER" == "true" ]; then
        sudo apt install ntp slurm-wlm nfs-common
        sudo systemctl enable slurmctld
        sudo systemctl start slurmctld

    elif [ "$IS_DB" == "true" ]; then
        sudo apt install nfs-kernel-server slurm-client slurmd
        sudo mv $TMP_EXPORT_CONF /etc/exports
        sudo mv $TMP_HOST_ALLOW_CONF /etc/hosts.allow
    	sudo mount -a
    	sudo exportfs -a

    else
        sudo apt install slurm-client slurmd

    fi
    sudo mkdir -p /clusterfs /etc/slurm
    sudo chown nobody:nogroup -R /clusterfs
    sudo chmod -R 777 /clusterfs

    echo $HOSTNAME > hostname.tmp

    sudo mv hostname.tmp /etc/hostname
    sudo mv $TMP_DHCP_CONF /etc/dhcpcd.conf
    sudo mv $TMP_NTP_CONF /etc/ntp.conf
    sudo mv $TMP_HOSTS_CONF /etc/hosts
    sudo mv $TMP_FSTAB_CONF /etc/fstab
    sudo mv $TMP_SLURM_CONF /etc/slurm/slurm.conf
    sudo mv $TMP_CGROUP_ALLOWED_DEVICES_FILE /etc/slurm/cgroup-allowed-devices.conf
    sudo mv $TMP_CGROUP_CONF /etc/slurm/cgroup.conf


    sudo systemctl enable slurmd
    sudo mount -a
    echo "Please Reboot once confirmed that everything is working."
fi

