#!/bin/bash
# http://wiki.bash-hackers.org/howto/getopts_tutorial
# trailing colon means switch needs argument. Leading colon means silent error reporting (vs. verbose).
#
# one also needs to prepare the iso file structure. Just dropping the installer iso in this location won't help
# for howto: https://docs.vmware.com/en/VMware-vSphere/6.7/com.vmware.esxi.upgrade.doc/GUID-C03EADEA-A192-4AB4-9B71-9256A9CB1F9C.html
OUTPUT=/export/VMW/hosts
COPYTO=ks.cfg
#
if [ "$1" == '' ]; then
	echo "Usage: ${0##*/} -n hostname -m NETMASK -g GATEWAY -v VLAN -i image -k ks"
	echo ""

	echo "- copy/paste one of the follow image paths:"
	ls -1d /export/VMW/{5,6,7}.*/* 2>/dev/null
	echo ""
	echo "- Use one of the following ksconfig (or roll your own):"
	ls /export/VMW/ksconfigs
	echo ""
	exit 1
fi

while getopts :n:i:k:m:g:v: opt; do
	case $opt in
		i) IMAGE=$OPTARG;;
		n) HOST=$OPTARG;;
		k) KS=$OPTARG;; 
		m) MASK=$OPTARG;;
		g) GATEWAY=$OPTARG;;
		v) VLAN=$OPTARG;;
		:) echo "Option -$OPTARG requires an argument."; exit 1;;
		*) echo "Invalid option: -$OPTARG"; exit 1;;
	esac
done

####
if [[ -z $IMAGE || -z $HOST || -z $KS || -z $MASK || -z $GATEWAY || -z $VLAN ]]; then
	echo "Missing options!"
	printf "%9s%-20s\n" 'IMAGE: ' ${IMAGE:-?}
	printf "%9s%-20s\n" 'HOST: ' ${HOST:-?}
	printf "%9s%-20s\n" 'KS: ' ${KS:-?}
	printf "%9s%-20s\n" 'GATEWAY: ' ${GATEWAY:-?}
	printf "%9s%-20s\n" 'VLAN: ' ${VLAN:-?}
	echo "Usage: ${0##*/} -n hostname -m NETMASK -g GATEWAY -v VLAN -i image -k ks"
	echo ''
	exit 1;
fi
if [ ! -f $IMAGE/boot.cfg ]; then
	echo "$IMAGE directory does not contain a file 'boot.cfg'"
	echo "please extract all files from the installer iso"
	echo "You can mount the installer iso like this: mount -o loop installer_iso /tmp/a"
	echo "Then copy all files to your image directory: cp -r /tmp/a/* $IMAGE/"
	echo ''
	exit 1
fi

KS=/export/VMW/ksconfigs/$KS

# normalize your hostname with domain if not yet
[[ "$HOST" =~ vmware.com ]] || HOST="$HOST.vmware.com"
IP=$(dig +short $HOST 2>/dev/null)
if [ "$IP" == '' ]; then
	echo "host not in DNS!"
	echo "Make sure create DNS record and it is in all dns slave servers."
	exit 1
fi

# use \K to keep this part of the pattern
perl -pi -e "s;--ip=\K(\d+.\d+.\d+.\d+)?;$IP; unless /^#/" $KS
perl -pi -e "s;--gateway=\K(\d+.\d+.\d+.\d+)?;$GATEWAY; unless /^#/" $KS
perl -pi -e "s;--hostname=\K(.*[^\S\n]+)?;$HOST ; unless /^#/" $KS
perl -pi -e "s;--netmask=\K(\d+.\d+.\d+.\d+)?;$MASK; unless /^#/" $KS
perl -pi -e "s;--vlanid=\K(\d+.)?;$VLAN; unless /^#/" $KS

#####
# files with similar name is not good - you won't knwo which copy will be used
echo "Adding $KS to $IMAGE as $COPYTO..."
rm -f $IMAGE/ks.cfg*
cp $KS $IMAGE/$COPYTO
# also make sure this line replaces the kernelopt line in the boot.cfg file
#kernelopt=runweasel
#kernelopt=runweasel ks=cdrom:/KS.CFG nameserver=10.113.61.110
perl -pi -e "s;^kernelopt=runweasel\K.*$; ks=cdrom:/KS.CFG nameserver=10.113.61.110;" $IMAGE/boot.cfg
#
echo "Making the final ISO. Please ignore the warning about ISO-9660..."
mkisofs -quiet -relaxed-filename -J -R -o $OUTPUT/$HOST.iso -b isolinux.bin -c boot.cat -no-emul-boot -boot-load-size 4 -boot-info-table $IMAGE/
echo ""
echo "`egrep '^network' $KS`"
echo ""

echo "ISO ready: http://sc9-kickstart.vmware.com/VMW/hosts/$HOST.iso"
echo "We can also insert this as virtual media on the iLO  and trigger auto install if you want."
echo ""
