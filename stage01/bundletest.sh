#!/bin/bash

source ../lib/winqa_util.sh
setup_euca2ools;

hostbit=$(host_bitness)
guestbit=$(guest_bitness)
if [ $guestbit -eq "64" ] && [ $hostbit -eq "32" ]; then
    echo "Running 64 bit guest on 32 bit host"
    sleep 10
    exit 0
fi

cp ../etc/id_rsa.proxy ./
chmod 400 ./id_rsa.proxy
winimgs=$(euca-describe-images | grep windows | grep -v deregistered)
if [ -z "$winimgs" ]; then
        echo "ERROR: No windows image is found in Walrus"
        exit 1
fi
exitCode=0
IFS=$'\n'
for img in $winimgs; do
	if [ -z "$img" ]; then
		continue;
	fi
	IFS=$'\n'
        emi=$(echo $img | cut -f2)
	echo "EMI: $emi"

	unset IFS
   	ret=$(euca-describe-instances | grep $emi | grep -E "running")
	if [ -z "$ret" ]; then
		echo "ERROR: Can't find the running instance of $emi"
		exitCode=1
		break;
	fi
        instance=$(echo -e ${ret/*INSTANCE/} | cut -f1 -d ' ')
	if [ -z $instance ]; then
                echo "ERROR: Instance from $emi is null"
		exitCode=1
                break;
        fi
	zone=$(echo -e ${ret/*INSTANCE/} | cut -f10 -d ' ')
        ipaddr=$(echo -e ${ret/*INSTANCE/} | cut -f3 -d ' ')
	keyname=$(echo -e ${ret/*INSTANCE/} | cut -f6 -d ' ')
	
	if [ -z "$zone" ] || [ -z "$ipaddr" ] || [ -z "$keyname" ]; then
		echo "ERROR: Parameter is missing: zone=$zone, ipaddr=$ipaddr, keyname=$keyname"
		exitCode=1
		break;
	fi
	echo "Parameters- zone: $zone, ipaddr: $ipaddr, keyname: $keyname"
	keyfile=$(whereis_keyfile $keyname)
	
	if [ ! -s $keyfile ]; then
		echo "ERROR: can't find the key file";
		exitCode=1
		break;
	fi

  	cmd="euca-get-password -k $keyfile $instance"
        echo $cmd
        passwd=$($cmd)
        if [ -z "$passwd" ]; then
                echo "ERROR: password is null";
		exitCode=1
		break;
        else
                if should_test_guest; then
			echo "Password: $passwd"
                	ret=$(./login.sh -h $ipaddr -p $passwd)
                	if [ -z "$(echo $ret | tail -n 1 | grep 'SUCCESS')" ]; then
                       		 echo "ERROR: Couldn't login ($ret)";
				exitCode=1
				break;
                	fi
                fi
        fi
	
	# add new admin uname/passwd (let's not do it; it should work fine)
        if should_test_guest; then
             if [ $(get_networkmode) != "SYSTEM"  ]; then
                 ret=$(./admembership.sh)
	         if [ -n "$ret" ]; then
                     echo "Domain: $ret"
                     ret=$(./adddomrec.sh)
                     if [ -z "$(echo $ret | tail -n 1 | grep 'SUCCESS')" ]; then
                        echo "ERROR: couldn't add admin uname/pwd: $ret";
                        ret=$(./eucalog.sh)
                        echo "WINDOWS INSTANCE LOG: $ret"
                        exitCode=1
                        break;
                     else
                        echo "Updated domain info (ad controller/uname/passwd) for the next attachment";
                     fi
	         else
		     echo "The instance to be bundled is not attached to a domain"
                 fi
             fi
        fi
	sleep 10
	# bundle instance
	bucket=win$RANDOM
	prefix=windows-bundleof-$emi
	akey="$(echo $EC2_ACCESS_KEY)"
	skey="$(echo $EC2_SECRET_KEY)"
	echo "bucket: $bucket, prefix: $prefix, akey: $akey, skey: $skey"	
	ret=$(euca-describe-bundle-tasks)
	if ! echo $ret | grep $instance; then	
	
		ret=$(euca-bundle-instance -b $bucket -p $prefix -o $akey -w $skey $instance)	
		if ! echo $ret | grep 'BUNDLE'; then
			echo "ERROR: bundle instance failed: $ret"
			exitCode=1
			break;
		fi
		bundleid=$(echo $ret | cut -f2 -d ' ')
	else
		bundleid=$(echo $ret | cut -f2 -d ' ')
	fi

	if [ -z $bundleid ]; then
		echo "ERROR: bundle id is null"
		exitCode=1
		break;
	fi
	echo "Bundle ID: $bundleid"

	timeout=720	# wait upto 120 min.
	for (( i=1; i <= $timeout ; i++ ))
	do
                sleep 10
		ret=$(euca-describe-bundle-tasks | grep $bundleid)
		if [ -z "$ret" ]; then
			break;
		fi
		if echo "$ret" | grep 'complete'; then
			break;
		fi
		if echo "$ret" | grep 'failed'; then 
			break;
		fi
		echo "Waiting for bundle-task completion..."
        done

	if ! echo $ret | grep 'complete'; then
		echo "ERROR: bundle task failed: $ret"
		exitCode=1
		break;
	fi
	echo "Bundle task was complete"
	sleep 3
	manifest="$bucket/$prefix.manifest.xml"	
	ret=$(euca-register $manifest)	
	if ! echo $ret | grep IMAGE; then
		echo "ERROR: couldn't register the bundled image"
		exitCode=1
		break;
	fi
	sleep 10
	
	ret=$(euca-describe-images)
	if ! echo $ret | grep $prefix; then 
		echo "ERROR: Can't find the registered image from Walrus: $prefix"
		exitCode=1
		break;		
	fi

        echo "Now waiting for registration takes place..."      
	imgsize=$(cat ../etc/imgsize)
	echo "Image size: $imgsize"
        wait_for_unbundle $bucket $imgsize;

	echo "Image $prefix registered successfully"
done
chmod 666 ./id_rsa.proxy
exit "$exitCode"

