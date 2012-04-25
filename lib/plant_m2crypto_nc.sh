#!/bin/bash

nclist=$(cat ../input/2b_tested.lst | grep '\[NC')
IFS=$'\n'

for ncnode in $nclist; do
	unset IFS
	ipaddr=$(echo $ncnode | cut -f1 -d ' ')
	distro=$(echo $ncnode | cut -f2 -d ' ')
	
	cmd=""	
	if [ $distro = "LUCID" ]; then
		cmd="apt-get install python-m2crypto";
	elif [ $distro = "UBUNTU" ]; then
		cmd="apt-get install python-m2crypto";
	elif [ $distro = "KARMIC" ]; then
		cmd="apt-get install python-m2crypto";
	elif [ $distro = "CENTOS" ]; then
		cmd="yum install m2crypto";
	elif [ $distro = "DEBIAN" ]; then
		cmd="apt-get install python-m2crypto";
	elif [ $distro = "OPENSUSE" ]; then
		cmd="yum install m2crypto";
	else
		echo "Unknown distro: $distro";
		break;	
	fi
	echo "installing m2crypto on $ipaddr"	
	ret=$(ssh root@$ipaddr "$cmd")		
	echo "result: $ret"
done
exit 0
