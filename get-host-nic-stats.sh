#!/bin/bash
#
# please enable key based login to the esxi host for this to work.
#
if [ "$1" == '' ]; then echo "$0 hostname"; exit; fi
HOST=$1
echo $HOST
#
# need to get anything with "errors:" or "dropped:" with a non-zero value. Also adding total RX/TX
ssh -n -o ConnectTimeout=3 $HOST "esxcli network nic list | grep vmnic | awk '\$5 == \"Up\"' | awk '{print \$1\"  \"\$3}' | \
	while read nic driver; do \
		echo -e \"\$nic (\$driver): \c\"; \
		esxcli network nic stats get -n \$nic | \
		awk '(\$3~/errors:|dropped:/ && \$4 != 0)|| \$1~/Packets/ {if (\$4) {print \$1\".\"\$2\".\"\$3\" \"\$4} else if (\$2~/received/) {print \"RX: \"\$3} else {print \"TX: \"\$3 }}' | \
		xargs; \
	done | \
	sort -n -tc -k2" | \
	column -t
