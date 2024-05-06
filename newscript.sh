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
CONFIG_PATH=./newdave.conf.test
TMP_NTP_CONF=./ntp.conf.tmp
TMP_DHCP_CONF=./dhcpcd.conf.tmp
TMP_HOSTS_CONF=./hosts.tmp
TMP_FSTAB_CONF=./fstab.tmp
TMP_SLURM_CONF=./slurm.conf.tmp


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
$HOSTNAME_BASE$NODE_ID
option host_name

# Static IP Setup
profile $HOSTNAME_BASE
static ip_address=${IP_ADDR_LIST[$NODE_ID]}
static routers=${SUBNET}1

interface eth0
fallback $HOSTNAME_BASE

EOF


# Build /etc/ntpsec/ntp.conf
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
fi



if [ "$DEBUG" == "true" ]; then
    echo "HostBase: $HOSTNAME_BASE"
    echo "NodeList: ${NODE_NAME_LIST[*]}"
    echo "IPList: ${IP_ADDR_LIST[*]}"
    echo "IPMaserList: ${MASTER_IP_LIST[*]}"
else
    echo "DEBUG FALSE"
    sleep 2
fi

