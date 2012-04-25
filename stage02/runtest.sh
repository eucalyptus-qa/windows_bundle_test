#!/bin/bash

# make sure there's an existing image
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

winimgs=$(euca-describe-images | grep windows | grep bundleof)
if [ -z "$winimgs" ]; then
	echo "ERROR: No windows image is found in Walrus"
	exit 1
fi	

# pick a keypair (should be in ../stage02/mykey{n}.priv
keypairs=$(euca-describe-keypairs | head -n 1)
echo $keypairs
set -- $keypairs
keyname=$2
keyfile=$(whereis_keyfile $keyname)
if [ ! -s $keyfile ]; then
     echo "ERROR: Keyfile not found in $keyfile";
     exit 1
fi

# detect or create a security group 
group=$(euca-describe-groups | head -n 1)
if echo $group | grep GROUP; then 
	set -- $group
	group=$3	
else
	echo "No security group is found"
	if ! euca-add-group -d wingroup wingroup | grep GROUP ; then
		echo "ERROR: can't add a security group"
		exit 1
	fi	
	group="wingroup";
fi
sleep 1
# authorize windows ports
if ! euca-describe-groups | grep $group | grep 3389; then
	ret=$(euca-authorize -P tcp -p 3389 -s 0.0.0.0/0 $group)
	if [ -z "$(echo $ret | grep 'PERMISSION')" ]; then
       	  echo "ERROR: could not authorize RDP port to the group"
       	  exit 1
	fi
fi
sleep 1
if ! euca-describe-groups | grep $group | grep 5985; then
	ret=$(euca-authorize -P tcp -p 5985-5986 -s 0.0.0.0/0 $group)
	if [ -z "$(echo $ret | grep 'PERMISSION')" ]; then
       	  echo "ERROR: could not authorize WINRM port to the group"
       	  exit 1
	fi
fi

hypervisor=$(describe_hypervisor)
echo "Hypervisor: $hypervisor"

#foreach windows EMI
IFS=$'\n'
retry=2
for img in $winimgs; do
  while [ $retry -gt 0 ]; do
        ((retry--))
        exitCode=0
	if [ -z "$img" ]; then 
		break;
	fi
	IFS=$'\n'
	echo "Walrus image: $img"
	emi=$(echo $img | cut -f2)
	echo "EMI: $emi"
	ret=$(euca-describe-instances | grep $emi | grep -E "running|pending" )
	if [ -z "$ret" ]; then	
                timeout=18  #180 seconds
                i=0
                while [ 1 ]; do
		    ret=$(euca-run-instances -k $keyname -g $group -t m1.xlarge $emi)	
	            if !(echo $ret | grep INSTANCE;); then
       		        echo "ERROR: Instance not created ($ret)"
                        sleep 10
			exitCode=1
                    else       
                        exitCode=0
                        break
	            fi
                    ((i++))
                    if [ $i -gt $timeout ]; then
                         echo "Wait time expired"       
                         break;
                    fi            
                done
                if [ $exitCode -eq 1 ]; then
                   # break;
                    echo "Instance run will retry $retry times"
                    sleep 120;
                    continue;
                fi
	        echo "Instance created"
	fi
	sleep 5
	unset IFS
	ret=$(euca-describe-instances | grep $emi | grep -E "running|pending")
	instance=$(echo -e ${ret/*INSTANCE/} | cut -f1 -d ' ')
	
	if [ -z $instance ]; then
		echo "ERROR: Instance is null"
		exitCode=1
                sleep 120
                continue;
	fi

	timeout=360  # wait for 3600 seconds
	i=0	
	# wait until instance becomes running
	nonpending=1
	#while echo $(euca-describe-instances $instance) | grep "pending" > /dev/null; do
	while [ 1 ]; do
		ret=$(euca-describe-instances $instance)
		if ! echo "$ret" | grep 'pending' > /dev/null; then
			((nonpending++))
		fi
		if echo "$ret" | grep 'running' > /dev/null; then
			break;
		fi
			
		if [ $nonpending -gt 3 ]; then
			echo "instance was not in pending state in previous 3 queries"
			break;
		fi

       		sleep 10
        	echo "Instance ($instance) pending: $(date)" 
		((i++))
                if [ $i -gt $timeout ]; then
			echo "Wait time expired"
                        break;
                fi
	done

#	ret=$(euca-describe-instances "$instance")
	if ! echo "$ret" | grep 'running'; then
       	      echo "ERROR: Instance is not running ($ret)" 
	      exitCode=1
              echo "Instance test failed; will retry $retry times"
              ret=$(euca-terminate-instances $instance)
              sleep 120        
              continue;
	fi
	ipaddr=$(echo -e ${ret/*INSTANCE/} | cut -f3 -d ' ')
	zone=$(echo -e ${ret/*INSTANCE/} | cut -f10 -d ' ')   

	echo "Instance running with IP address: $ipaddr, at zone: $zone"
	echo "Waiting for 7 minutes of booting time (sysprep takes this long to boot)"
	sleep 420	# wait for 7 mins
	if [ -z $ipaddr ]; then
                echo "ERROR: address is null"
		exitCode=1
                #break;
        fi

        cmd="euca-get-password -k $keyfile $instance"
        echo $cmd
        passwd=$($cmd)
        if [ -z "$passwd" ]; then
                echo "ERROR: password is null"
		exitCode=1
                #break;
        fi
        echo "Password: $passwd"
       
        if ! should_test_guest; then
                echo "[WARNING] We don't perform guest test for this instance";
                sleep 10;
                continue;
        fi

        numtry=2;
        k=0;
        while [ $k -lt $numtry ]; do
             ret=$(./login.sh -h $ipaddr -p $passwd)

             if [ -n "$(echo $ret | tail -n 1 | grep 'SUCCESS')" ]; then
                 echo "Log-in instance successfull"
                 break
             else
                 echo "ERROR: Login test($ret)"
                 sleep 180;  # wait for extra 3 mins
             fi  
             ((k++))
        done

        if [ $k -ge $numtry ]; then
            exitCode=1;
            echo "ERROR: Login test eventually failed!"
            continue;
        fi

	ret=$(./rdp.sh)
	if [ -z "$(echo $ret | tail -n 1 | grep 'SUCCESS')" ]; then
       	 	echo "ERROR: RDP test ($ret)"
		exitCode=1
		ret=$(./eucalog.sh)
		echo "WINDOWS INSTANCE LOG: $ret"
	else
		echo "passed RDP test";
	fi
	
	echo $instance > "iname"
	ret=$(./hostname.sh)
	if [ -z "$(echo $ret | tail -n 1 | grep 'SUCCESS')" ]; then
       		echo "ERROR: Hostname setting test ($ret)"; 
		exitCode=1
		ret=$(./eucalog.sh)
                echo "WINDOWS INSTANCE LOG: $ret"
	else
		echo "passed hostname test"	
	fi
		
	if [ $hypervisor == "kvm" ]; then
		echo "Testing virtio drivers"
       		 ret=$(./virtio.sh);
	elif [ $hypervisor == "xen" ]; then
		echo "Testing Xen PV drivers"
       		 ret=$(./xenpv.sh);
	else
		 ret="SUCCESS"
	fi

	if [ -z "$(echo $ret | tail -n 1 | grep 'SUCCESS')" ]; then
       	 	echo "ERROR:  paravirtuzliation driver test ($ret)"; 
		exitCode=1
		 ret=$(./eucalog.sh)
                echo "WINDOWS INSTANCE LOG: $ret"
	else
	        echo "Passed paravirt driver test (hypervisor: $hypervisor)";
	fi
	
	if [ $exitCode -eq 0 ]; then	
	      echo "Instance $instance passed all tests";
              break;
        else
              echo "Instance test failed;  will retry $retry times"  
               if [ $retry -gt 0 ]; then                  
                   ret=$(euca-terminate-instances $instance)          
                   echo "instance terminated before retry"
                   sleep 120
               fi
	fi
  done # retry
done # for each image
exit "$exitCode"
