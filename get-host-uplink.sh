#!/bin/bash
#
# please enable key based login to the esxi host for this to work.
#
if [ "$1" == '' ]; then echo "$0 hostname"; exit; fi
HOST=$1
echo "$HOST"
ssh -n -o ConnectTimeout=3 $HOST 2>/dev/null "
	esxcli network nic list | grep vmnic | awk '\$5 == \"Up\"'| awk '{print \$1\" \"\$3}'| \
	while read nic drv; do
		echo -e \"\$nic (\$drv \c\";
		esxcli network nic get -n \$nic | grep Version: | xargs | sed -e 's/Firmware Version: //' | sed -e 's/Version: /Drv:/' | xargs echo -n;
		echo -e \") \c\";
		vim-cmd hostsvc/net/query_networkhint --pnic=\$nic | \
		egrep 'System Name|devId|portId' -A 1 | \
		egrep -v 'timeToLive|key|--|address|deviceCap' | \
		grep -oE '\".*\"' | sed -e 's/(.*)//' | xargs | sed -e 's/.vmware.com//'
	done | \
sort -n -tc -k2"
#sort -n -tc -k2" | column -t
