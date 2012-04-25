#!/bin/bash

source ../lib/winqa_util.sh

hostbit=$(host_bitness)
guestbit=$(guest_bitness)
if [ $guestbit -eq "64" ] && [ $hostbit -eq "32" ]; then
    echo "Running 64 bit guest on 32 bit host"
    sleep 10
    exit 0
fi

if [ $(get_networkmode) = "SYSTEM"  ]; then
      echo "NETWORK MODE is system; don't need to reset VNET_DNS"
      sleep 10
      exit 0
fi

hypervisor=$(describe_hypervisor)
echo "Hypervisor: $hypervisor"

IFS=$'\n'
cc=$(cat ../input/2b_tested.lst | grep 'CC0'); 
if [ -z "$cc" ]; then
    echo "Can't find CC line in the machine list"
    exit 1
fi
unset IFS
set -- $cc 
ipaddr=$(echo "$1")
if [ -z "$ipaddr" ]; then
    echo "CC's ipaddress is not found"
    exit 1
fi
echo "CC's ip address: $ipaddr"
if ! ../lib/update_eucaconf.sh -h $ipaddr -p VNET_DNS -v "192.168.23.10"; then
    echo "Can't update VNET_DNS"
    exit 1;
fi
echo "updated VNET_DNS to 192.168.23.10"

eucaroot=$(whereis_eucalyptus CC)
ssh -o StrictHostKeyChecking=no root@$ipaddr "$eucaroot/etc/init.d/eucalyptus-cc cleanrestart"
echo "CC clean restared"

exit 0
