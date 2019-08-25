#!/usr/bin/perl -w
use strict;
use warnings;
use VMware::VILib;
use VMware::VIRuntime;
use Term::ANSIColor;
use VMware::VICredStore;
use Term::ReadKey; # install libterm-readkey-perl on Ubuntu
use POSIX qw(strftime);
##############################################
# migrate and clone ANY vm between ANY VCs.  #
##############################################
# Written by: Zaigui Wang, June 2016.
# Necessitated by: data center migration project of 2017-2018
# Inspired by: http://www.virtuallyghetto.com/2016/05/automating-cross-vcenter-vmotion-xvc-vmotion-between-the-same-different-sso-domain.html
#
my %opts = ( 
	op => {type=> "=s", help => "Operation type. any one of: move|migrate|vmotion|clone|copy|duplicate.", required => 1},
	vm => { type => "=s", help => "Source Virtual Machine", required => 1},
	host => { type => "=s", help => "Target ESXi host", required => 1},
	cluster => { type => "=s", help => "Target cluster. Not implemented yet", required => 0},
	rp => { type => "=s", help => "Optional: Target resource pool. Host/Cluster info can be derived from it", required => 0, default => 'Resources'},
	newvm => { type => "=s", help => "Optional: Target Virtual Machine Name for clone & move", required => 0},
	server2 => { type => "=s", help => "Target VC. Assume same vc when omitted.", required => 0},
	ds => { type => "=s", help => "Target datastores. Comma to separate multiples & unique ds. If one ds provied, collapse them to one.", required=>0},
	folder => { type => "=s", help => "Target folder name. Use the -folderID to narrow down if multiple of same name exist", required => 0, default => 'vm'},
	folderID => { type => "=s", help => "Target folder object ID.", required => 0},
	network => { type => "=s", help => "Target networks. One per NIC. Comma to specify multiples (a,b,,d). Same networks if none provided",required=>0},
	snapshot => { type => "=s", help => "Optional: Snapshot to clone from. First match when multiple of same name exist.", required => 0},
	skipdisk => { type => "=s", help => "Optional: Disks to exclude in the clone. For example 0:0. Use comma to delimit multiples", required => 0},
	nowait => { type => "", help => "Not wait for task to complete (a task cannot be canceled from this UI).", required => 0},
	dryrun => { type => "", help => "dryrun/whatif to verify whether the proposed operation is feasible.", required => 0},
	nostamp => { type => "", help => "Do not append operation stats to vm annotation - for xVC ops only", required => 0},
);
delete $ENV{'https_proxy'};
Opts::add_options(%opts);
Opts::parse();
Opts::validate();
##
my $domain = 'vmware.com';
my $MOVE = qr/^(move|migrate|vmotion)$/i; # regex pattern for migrate
my $CLONE = qr/^(clone|copy|duplicate)$/i;# regex pattern for clone
my $op = Opts::get_option('op'); die "Invalid Operation type specified!" unless ($op =~ $MOVE || $op =~ $CLONE);
my $vmname = Opts::get_option('vm');
my $newvm = Opts::get_option('newvm'); 
if ($op =~ $CLONE && !$newvm) { $newvm = $vmname.'.clone';}
my $cloneto = ($newvm)?"as $newvm":'';
my $host = Opts::get_option('host'); 
my $cluster = Opts::get_option('cluster'); 
$host .= '.'.$domain unless ($host =~ /$domain/ || !$host || $host =~ /\d+\.\d+\.\d+\.\d+/); 
die ("Need target host/cluster!") unless ($host || $cluster);
my $srcVC = Opts::get_option('server');
my $dstVC = Opts::get_option('server2');
my $ds_string = Opts::get_option('ds'); 
my @dss = split(',', $ds_string) if ($ds_string);
my $pg_string = Opts::get_option('network'); my @pgs = split(',', $pg_string) if ($pg_string);
my $rp = Opts::get_option('rp');
my $folder = Opts::get_option('folder');
my $folderID = Opts::get_option('folderID');

# username and password will be automatically looked up from the credential store, Or prompted at the validation time
my $username = Opts::get_option('username');
my $password = Opts::get_option('password');
my $skipdisk_string = Opts::get_option('skipdisk');
my %skipdisk = map {$_ => 1} split(',', $skipdisk_string) if ($skipdisk_string);
if (%skipdisk && $op =~ $MOVE) {
	print color("red")."Skipdisk applicable to clone operation only. Ignored!...\n".color('reset');
}
my $nowait = Opts::option_is_set('nowait');
my $dryrun = Opts::option_is_set('dryrun');
my $nostamp = Opts::option_is_set('nostamp');
my $snapshotName = Opts::get_option('snapshot');

###
my ($event, $srcVIM, $dstVIM, $vm_view, $host_view, $rp_view, $fd_view,$sessionFreshness);
my @endpoint = (); #only need if cross-vc.
if ($srcVC) {$srcVC .= '.'.$domain unless ($srcVC =~ /$domain/ || $srcVC =~ /\d+\.\d+\.\d+\.\d+/)};
if ($dstVC) {$dstVC .= '.'.$domain unless ($dstVC =~ /$domain/ || $dstVC =~ /\d+\.\d+\.\d+\.\d+/)};

print "Establishing source VC connection - ";
$srcVIM = &create_session($srcVC, $username, $password);
exit unless $srcVIM->{service_content}; # a failed connection would not have service_content
print color($sessionFreshness)."UUID: " . ${$srcVIM->get_service_content()}{'about'}->{'instanceUuid'} . "\n".color('reset');

# if no Target VC specificed, or specificed the same VC sans the domain name. Set Target to source
my $xvc = 0;
my ($user2,$pass2);

#figure out the action verb present and past tenses
my $char = chop (my $word = $op);
my $doing  = ($char =~ /(e|E)/)?$word.'ing':($char =~ /(y|Y)/)?$word.'ying':$word.$char.'ing';
my $done  = ($char =~ /(e|E)/)?$word.'ed':($char =~ /(y|Y)/)?$word.'ied':$word.$char.'ed';
#
#We assume the destination VC uses the same user. Deal with it otherwise later.
$user2 = $username;
$pass2 = $password;
if (!$dstVC || $srcVC eq $dstVC) {
	$event = "$doing $vmname to $host $cloneto in $srcVC";
	$dstVC = $srcVC;
	$dstVIM = $srcVIM;
} else { 
	$xvc = 1;

	# login logic. You might need to adjust to your needs. 
	# 1. first, try same user/pass as source 
	# 2. if failed, look up in credstore 
	# 3. if still failed, prompt for it
	print "Establishing Target VC connection - "; 
	$dstVIM = &create_session($dstVC, $user2, $pass2);
	if (! $dstVIM->{service_content}) {
		my @username = ();
		my $found = 0;
		my $gotuser = 0;

		# let's look into the credstore
		if (VMware::VICredStore::init()) { 
			@username = VMware::VICredStore::get_usernames (server => $dstVC);
			if (@username) {
				# let's see if the same user exist in credstore on destination side
				foreach (@username) {
					if ($_ = $user2) { 
						$pass2 = VMware::VICredStore::get_password(server => $dstVC, username => $user2);
						$found = 1;
						print "Retrieved destination VC credential from credstore...\n";
					}
				}

				if (! $found) {
					print "$dstVC Username: "; ($user2 = ReadLine(0)) =~ s/[\r\n]+//g;
					$gotuser = 1;
					foreach (@username) {
						if ($_ = $user2) {
							$pass2 = VMware::VICredStore::get_password(server => $dstVC, username => $user2);
							$found = 1;
							print "Retrieved destination VC credential from credstore...\n";
						}
					}
				}
			}
		}

		# Not in credstore. so let's ask
		if (! $found) {
			if (! $gotuser) {
				print "$dstVC Username: ";
				($user2 = ReadLine(0)) =~ s/[\r\n]+//g;
			}
			print "$dstVC Password: "; ReadMode 2; ($pass2 = ReadLine(0)) =~ s/[\r\n]+//g; ReadMode 0; print "\n";
		}
	}

	$dstVIM = &create_session($dstVC, $user2, $pass2);
	exit unless $dstVIM->{service_content};
	print color($sessionFreshness). "UUID: " . ${$dstVIM->get_service_content()}{'about'}->{'instanceUuid'} . "\n".color('reset');
	$event = "$doing $vmname in $srcVC to $host $cloneto in $dstVC";
	
	# build up the service locator, with ssl thumbprint, etc
	use Net::SSLeay qw(get_https3);
	my ($page, $response, $headers, $cert) = get_https3($dstVC, 443, '/');
	my $fingerprint = Net::SSLeay::X509_get_fingerprint($cert, "sha1");
	my $cred = ServiceLocatorNamePassword->new(username=>$user2, password=>$pass2);
	my $url="https://$dstVC";
	my $uuid = ${$dstVIM->get_service_content()}{'about'}->{'instanceUuid'};
	my $service = ServiceLocator->new(credential=>$cred, sslThumbprint=>$fingerprint, instanceUuid=>$uuid , url=>$url);
	@endpoint = (service => $service);
}

# SOURCE: VM and its whereabout
my @vmproperty = (properties=>['name','config.files.vmPathName','config.hardware.device','config.annotation','runtime.host','runtime.powerState', 'snapshot']);
$vm_view = $srcVIM->find_entity_view(view_type=>'VirtualMachine', filter=>{'name'=>qr/^$vmname$/i}, @vmproperty);
&cleanUp("Unable to find VM $vmname in $srcVC") unless $vm_view;

# CLONE only: figure out snapshot. If requested, confirm snapshot exist; Otherwise, set snapshot parameter to null for virtualmachineclonespec;
# If multiple snapshot of the same name found, we only care about the first match. Rename snapshot with unique names
my @snap = ();
if ($snapshotName && $op =~ $CLONE) {
	if (defined $vm_view->snapshot) {
		my $rootsnap = $vm_view->snapshot->rootSnapshotList;
		if (${$rootsnap}[0]->name eq $snapshotName) {
			@snap = (snapshot => ${$rootsnap}[0]->snapshot);
		} elsif (defined ${$rootsnap}[0]->childSnapshotList) {
			my $childlist = ${$rootsnap}[0]->childSnapshotList;
			while ($childlist) {
				if (${$childlist}[0]->name eq $snapshotName) { @snap = (snapshot => ${$childlist}[0]->snapshot); last; }
				elsif (defined ${$childlist}[0]->childSnapshotList) { $childlist = ${$childlist}[0]->childSnapshotList; }
				else { undef $childlist; print "\n"; }
			}
		}
	}
	if (@snap) { print "Located snapshot \"$snapshotName\". Using that as source of the $op operation...\n";}
	else { &cleanUp("snapshot $snapshotName not found"); }
}

my $power = $vm_view->{'runtime.powerState'}->val;
my $h = $srcVIM->get_view(mo_ref=>$vm_view->{'runtime.host'}, properties => ['name']);
&cleanUp("Already on host. Exiting...") if ($h->name eq $host && $op =~ $MOVE);

# modify the event to add the source host
$event =~ s/\bto\b/from $h->{'name'} to/;
$event =~ s/\.$domain//g;

# SOURCE: Collect NIC/vmdk info. Controller numbers have to be calculated, while the unit # is readily available
my (@nics, @vmdks, @vmdkToKeep, @vmdkChangeSpec, $ctrl, %ctrls, $media);
my $devs = $vm_view->{'config.hardware.device'};
foreach (sort {$a->key cmp $b->key} @{$devs}) {
	if ($_->isa('VirtualEthernetCard')) {push (@nics, $_);}
	if ($_->isa('VirtualSCSIController')) { ($ctrl = $_->deviceInfo->label) =~ s/\D//g; $ctrls{$_->key} = $ctrl; }
	if ($_->isa('VirtualDisk')) { push(@vmdks, $_);}
	if ($_->isa('VirtualCdrom')) { $media = $_->deviceInfo->label . " is connected to ". $_->backing->fileName if ($_->connectable->connected); }
}

# For clone, we skip independent disks and any other disks as requested. 
# For move, all disks will need to go along
if ($op =~ $CLONE) {
	foreach (sort {$a->key cmp $b->key} @vmdks) {
		my ($diskBus, $diskUnit) = ($ctrls{$_->controllerKey}, $_->unitNumber);
		my $slot = $diskBus . ":" . $diskUnit;

		# skip only if they are independent persistent disks, have been requested, AND vm is powered on 
		if ($_->backing->diskMode eq 'independent_persistent' && $power eq 'poweredOn') {
			print "\tSkipping independent disk " . $_->deviceInfo->label.": ".$_->backing->fileName . "\n";
			push(@vmdkChangeSpec, VirtualDeviceConfigSpec->new(device=>$_, operation=>VirtualDeviceConfigSpecOperation->new('remove')));
		} elsif ($skipdisk{$slot}) {
			print "\tSkipping per request " . $_->deviceInfo->label.": ".$_->backing->fileName . "\n";
			push(@vmdkChangeSpec, VirtualDeviceConfigSpec->new(device=>$_, operation=>VirtualDeviceConfigSpecOperation->new('remove')));
		} else { push(@vmdkToKeep,$_);}
	}
} else { @vmdkToKeep = @vmdks;}

# Target host (or cluster) 
$host_view = $dstVIM->find_entity_view(view_type => 'HostSystem', filter=>{'name' => $host}, properties => ['name','parent','datastore','runtime.inMaintenanceMode','network']);
&cleanUp("ESX host $host in $dstVC not found!") if (!$host_view);
&cleanUp("ESX host in maintenance mode!") if ($host_view->{'runtime.inMaintenanceMode'} =~ /^true$/i);
print "Target host: $host (" . $host_view->{'mo_ref'}->{'value'}.")\n";

# backtracking to the target DC. Will use the DC as the begin_entity for folder search, to avoid confusion in case of multiple DCs in the VC.
my $dc = $dstVIM->get_view(mo_ref => $host_view->parent, properties => ['name','parent']);
while (ref($dc) ne 'Datacenter') { $dc = $dstVIM->get_view(mo_ref => $dc->parent);}
print "Target DC: ". $dc->name ." (". $dc->{'mo_ref'}->{'value'} . ")\n";

# Target datastores
#my @disk=();
my @diskLocator;
my $dstDsCount=0;
my %seen=();
my %dssMap=();# this maps srcDsName to dstDS
my $dstDs; #temporary variable for diskLocator
my $cfgDs; # relospec need 'datastore' information. This is the config location. defaulting the first ds, or the current vmx location.
print "Target datastores:\n";

# sort disks by label in order of "hard disk #1, #2, etc..."
foreach my $vmdk (sort {(split(/ /, $a->deviceInfo->label))[2] <=> (split(/ /, $b->deviceInfo->label))[2]} @vmdkToKeep) {
	my $srcDsName = $vmdk->backing->fileName =~ s/\[(.*?)\].*/$1/r;

	# datastore placement: if ds provided on command line, use that DS; 
	# if ds not provided on command line, use previous DS; if previous ds does not exist, use ds of same name.
	if (!$seen{$srcDsName}++) { # requiring a new datastore

		# destination not provided.
		if (! $dss[$dstDsCount]) {
			if ($dstDsCount) { $dss[$dstDsCount] = $dss[$dstDsCount-1];}# use previous one if exists
			else { $dss[$dstDsCount] = $srcDsName; } # assume the same as source. only happens if the first DS is not even provided
		}

		# now look to see if it exist on Target side
		# we could use a pattern here as well, instead of strict match. eq vs =~. 
		# However is it fair to always quit upon the first match? Maybe we should use the ds with the most free space.
		# my @pick = sort { $b->info->freeSpace <=> $a->info->freeSpace } grep { $_->name =~ $pattern } @ds; and just return $pick[0]
		my $ds_temp;
		foreach (@{$host_view->datastore}) { 
			if (${$dstVIM->get_view(mo_ref=>$_, properties=>['name'])}{name} eq $dss[$dstDsCount]){ $ds_temp = $_;}
		}
		if (!$ds_temp) { &cleanUp("ERROR: Unable to find datastore $dss[$dstDsCount] on host $host");}

		# OK we found the dstination ds ($ds_temp)
		$dstDs= $ds_temp;
		$dssMap{$srcDsName} = $ds_temp;

		# use the 1st datastore as the cfg ds
		$cfgDs = $ds_temp if ($dstDsCount == 0); 
		$dstDsCount++;
	} else { $dstDs= $dssMap{$srcDsName};} # otherwise, we've seen this ds before and know which dstDs it goes to

	print "\t*". $vmdk->deviceInfo->label . ": ". ${$dstVIM->get_view(mo_ref=>$dstDs, properties=>['name'])}{name}. " (". $dstDs->value . ")";
	# Can add diskBackingInfo here to force thin-provisioning, instead of using the deprecated disktransformation...
	# if dstDS is vSAN, we want to force thin-provisining by specifying diskBackingInfo thin...
	my @diskBackingInfo=();
	if (${$dstVIM->get_view(mo_ref=>$dstDs, properties=>['summary'])}{summary}{type} eq 'vsan' && !($vmdk->backing->thinProvisioned)) {
		print " [vSAN: enforcing thin-provisioned disk]\n"; 
		my $back = $vmdk->backing; 
		$back->{thinProvisioned} = 1;
		@diskBackingInfo = (diskBackingInfo => $back);
	} else {print "\n";}
	push @diskLocator, VirtualMachineRelocateSpecDiskLocator->new(diskId=>$vmdk->key, datastore=>$dstDs, @diskBackingInfo);
}

# Target resource pool (should be in the cluster)
$rp_view = $dstVIM->find_entity_view(view_type => 'ResourcePool', filter=>{'name'=>$rp}, begin_entity => $host_view->parent);
&cleanUp("ERROR: Unable to find the resource pool $rp on $host") unless $rp_view;
print "Target resource pool: $rp (". $rp_view->summary->config->entity->value. ")\n";

# Target folder (should be in the DC). Note that this parameter does not have to be set. We could set @folder = () unless folder is specified.
# When folder is specified and verified, we can set @folder = (folder => fd_view).
# Folders with the same name are allowed, even when on the same tree level.
my $fd_views = $dstVIM->find_entity_views(view_type => 'Folder', filter=>{'name' => qr/^$folder$/i}, begin_entity => $dc);
&cleanUp("ERROR: Unable to find the folder $folder in " . $dc->name) unless @$fd_views;
if (scalar(@{$fd_views} gt 1)) {
	my $chosen;

	if ($folderID) { $chosen = $folderID;}
	else {
		print color("red") . "Following folders found in the target DC:" . color("reset") . "\n";
		foreach (@$fd_views) { 
			my $path = Util::get_inventory_path($_, $dstVIM->get_vim());
			print "\t" . $_->{'mo_ref'}->value . ":\t$path\n";
		}
		print "Type folder ID from above (for example: group-vXXXX): ";
		($chosen = ReadLine(0)) =~ s/[\r\n]+//g;
	}

	foreach (@$fd_views) { if ($_->{'mo_ref'}->value eq $chosen) {$fd_view = $_; last;}}
	&cleanUp("$chosen is invalid in " . $dc->name) unless $fd_view;

} else {$fd_view = ${$fd_views}[0];}
print "Target folder: $folder (". $fd_view->{'mo_ref'}->{'value'}. ")\n";

# Target network details. For vss, pg name is all is required as pgs are unique; for vds, switch uuid and pg key are needed.
my (@devspec, $dstPgFound, $nicbacking);
my $num = 0;

# only go through this logic if network is specificed and vm has NICs. Why bother otherwise?
if (@pgs && @nics) {
	foreach my $nic (@nics) { 
		#if network name/pg for a nic is not provided via -network, grab source network/pg name as default
		if (! $pgs[$num]) {
			my $srcPG;
			# vds: 'VirtualEthernetCardDistributedVirtualPortBackingInfo'
			# vss: 'VirtualEthernetCardNetworkBackingInfo'
			# nsxt: 'VirtualEthernetCardOpaqueNetworkBackingInfo' (nsx.logicalswitch)
			if (ref($nic->backing) eq 'VirtualEthernetCardDistributedVirtualPortBackingInfo') {# if vds pg
				$srcPG = ${$srcVIM->find_entity_view(view_type=>"DistributedVirtualPortgroup",properties=>['name','key'],
					filter=>{key=>$nic->backing->port->portgroupKey})}{'name'};
			} elsif (ref($nic->backing) eq 'VirtualEthernetCardNetworkBackingInfo') {
				$srcPG = $nic->backing->deviceName;
			} elsif (ref($nic->backing) eq 'VirtualEthernetCardOpaqueNetworkBackingInfo') {
				$srcPG = ${$srcVIM->find_entity_views(view_type => "OpaqueNetwork", properties=>['summary'],
					filter=>{'summary.opaqueNetworkId' => $nic->backing->opaqueNetworkId})}{summary}{name};
					print "got nsxt pg: $srcPG\n";
			}
			$pgs[$num] = $srcPG =~ s;%2f;/;gr;
		}
		# now that we know the network we'll need, verify it exists on the target host.
		$dstPgFound = 0;
		foreach my $net (@{$host_view->network}) {
			my $nv = $dstVIM->get_view(mo_ref=>$net);
			(my $dstPG = $nv->name)  =~ s;%2f;/;g;;

			# DistributedVirtualPortgroup for vDS, Network for vSS, OpaqueNetwork for nsx-t port. Others for the future?
			my $netType = ($nv->summary->network->type eq 'DistributedVirtualPortgroup')?'vds':
				($nv->summary->network->type eq 'Network')?'vss':
				($nv->summary->network->type eq 'OpaqueNetwork')?'nvds':$nv->summary->network->type;

			# found something!
			if ($dstPG eq $pgs[$num]) {
				# case #1: to vDS. There is no restriction
				if ($netType eq 'vds') { 
					my $switchUuid = ${$dstVIM->get_view(mo_ref => $nv->config->distributedVirtualSwitch, properties => ['uuid'])}{'uuid'};
					my $pgkey = $nv->key;
					my $port = DistributedVirtualSwitchPortConnection->new(switchUuid=>$switchUuid, portgroupKey=>$pgkey);
					$nicbacking = VirtualEthernetCardDistributedVirtualPortBackingInfo->new(port=>$port);
					$dstPgFound = 1;

					#this nifty substitution operator: /r will copy the input, massage it and return the result, without changing the original.
					print "Target $netType network for " . $nic->deviceInfo->label =~ s/Network adapter /NIC #/r.": $dstPG ($pgkey)\n";
				}
				# case #2: to vSS. Live migration won't work from vDS to vSS. Otherwise fine. Within VC, work around it by re-assign the PG
				elsif ($netType eq 'vss') { 
					print "Target $netType network for " . $nic->deviceInfo->label =~ s/Network adapter /NIC #/r.": $dstPG\n";
					$nicbacking = VirtualEthernetCardNetworkBackingInfo->new(deviceName=>$dstPG);
					$dstPgFound = 1;
				}
				# NSX-T in play
				elsif ($netType eq 'nvds') {
					my $ID = $nv->summary->opaqueNetworkId;
					my $type = $nv->summary->opaqueNetworkType;
					print "Target $netType network for " . $nic->deviceInfo->label =~ s/Network adapter /NIC #/r.": $dstPG\n";
					$nicbacking = VirtualEthernetCardOpaqueNetworkBackingInfo->new(opaqueNetworkId=>$ID, opaqueNetworkType=>$type);
					$dstPgFound = 1;
				}
				# Future proofing - Who knows what this is...
				else { print "Target $netType network for " . $nic->deviceInfo->label =~ s/Network adapter /NIC #/r.": $dstPG\n";}
				last;
			}
		}

		# if portgroup found. 
		if ($dstPgFound) {
			$nic->backing($nicbacking);
			push(@devspec, VirtualDeviceConfigSpec->new(operation => VirtualDeviceConfigSpecOperation->new('edit'), device => $nic));
		} else {
			&cleanUp("Target network $pgs[$num] for ". $nic->deviceInfo->label =~ s/Network adapter /NIC #/r.": not found!");
		}
		$num++;
	}
}

# RelocateSpec: datastore, deviceChange, disk, diskMoveType, folder, host, pool, profile, service (if not provided, the current VC used)
# Should provide a cluster or resource pool here for DRS to pick a host...
my $migrationPriority = VirtualMachineMovePriority->new('defaultPriority');
my $reloSpec = VirtualMachineRelocateSpec->new( datastore => $cfgDs, host => $host_view, folder => $fd_view, pool => $rp_view, deviceChange => [@devspec], disk=>[@diskLocator], @endpoint,);

# Unfortunately disk remove still has to happen within 'config' spec, not 'location'. Not checking the size of @vmdkToDlete hoping null is OK.
my $vmconfig = VirtualMachineConfigSpec->new( deviceChange => [@vmdkChangeSpec],);
my $cloSpec = VirtualMachineCloneSpec->new( config => $vmconfig, location => $reloSpec, template => 0, powerOn => 0, @snap);

# this could be either clone or move
$event = ($dryrun)?"DRYRUN - $event":$event;
my $taskRef;
if ($op =~ $MOVE) { 
	if ($dryrun) {
		# OK let's catch snapshot...
		if (defined $vm_view->snapshot) {
			print color('red')."** Snapshots found: ". color('reset');
                        my $rootsnap = $vm_view->snapshot->rootSnapshotList;
                        print ${$rootsnap}[0]->name .' ('. ${$rootsnap}[0]->snapshot->value.') ['. ${$rootsnap}[0]->createTime.'] ';
                        if (defined ${$rootsnap}[0]->childSnapshotList) {
                                my $childlist = ${$rootsnap}[0]->childSnapshotList;
                                while ($childlist) {
                                        print " => ". ${$childlist}[0]->name .' ('.${$childlist}[0]->snapshot->value .')['. ${$childlist}[0]->createTime.'] ';
                                        if (defined ${$childlist}[0]->childSnapshotList) {
                                                $childlist = ${$childlist}[0]->childSnapshotList;
                                        } else {
                                                undef $childlist;
                                        }
                                }
                        }
			print "\n";
		}

		# if CDROM is mounted, warn:
		if ($media) { print color('red') . "** $media\n" . color('reset');}
		
		#CheckRelocate_Task(vm, spec, testtype). When testtype is not specified, all tests will be run
		my $checker = $srcVIM->get_view(mo_ref=>${$srcVIM->get_service_content()}{'vmProvisioningChecker'});
		eval {$taskRef = $checker->CheckRelocate_Task(vm=>$vm_view, spec => $reloSpec);};
	}
	else {
		# we can change the host name during the move, but change it on the source side.
		# it is possible that the new name might exist on source side already!
		# Note also that changing the vm name does not change the vm process on the current host (until the vm is migrated or restarted): esxcli network vm list
		if ($newvm) {
			print color('blue')."### Renaming the VM to $newvm on SOURCE side...\n".color('reset');
			my $vmConfigSpec = VirtualMachineConfigSpec->new (name => $newvm);
			$vm_view->ReconfigVM(spec => $vmConfigSpec);
		}
		eval {$taskRef = $vm_view->RelocateVM_Task(spec => $reloSpec, priority => $migrationPriority);}
	}
} else {
	my $existVM = $dstVIM->find_entity_view(view_type=>'VirtualMachine', filter=>{'name'=>$newvm}, properties=>['name']);
	&cleanUp("ERROR: VM with name $newvm exists!") if $existVM;

	if ($dryrun) {
		my $checker = $srcVIM->get_view(mo_ref=>${$srcVIM->get_service_content()}{'vmProvisioningChecker'});
		eval {$taskRef = $checker->CheckClone_Task(vm=>$vm_view, spec=>$cloSpec, folder=>$fd_view, name=>$newvm);};
	} else { eval {$taskRef = $vm_view->CloneVM_Task(spec => $cloSpec, name => $newvm, folder=>$fd_view);};}
}

###### Monitoring and cleanup
print $@ . "\n" if $@;
if ($taskRef) { &taskMonitor($taskRef, $srcVIM);}
&cleanUp("DONE!");

###### SUBS
sub cleanUp() {
	# OK, let's not logout since we are re-using sessions
	print "@_\n";
	exit 0;
}
sub taskMonitor() {
	if ($nowait) {
		print "Not tracking the task as requested.\n";
		return 1;
	}
	my $taskRef = shift;
	my $srcVIM = shift;
	my $taskID = $taskRef->{'value'};
	print color('blue'). "### Watching $taskID ###\n$event" .color('reset') . "\n";

	my $task = $srcVIM->get_view(mo_ref => $taskRef, properties => ['info']);
	my $lastmessage = '';
	print localtime(). "\n";
	print "Enter".color('red')." STOP ".color('reset'). "to cancel any time...\n" unless ($dryrun);

	# non-blocking wait input
	use IO::Select;
	my $input = IO::Select->new();
	$input->add(\*STDIN);

	$|=1; # autoflush
	while (($task->info->state->val eq 'running') or ($task->info->state->val eq 'queued')) {
		$task->update_view_data();
		if (defined $task->info->progress) {
			if (defined $task->info->description) {
				my $message = $task->info->description->message;
				if ($message && ($message ne $lastmessage)) {
					$lastmessage = $message; 
					print "\n";
				}
				print "\r\e[J". $task->info->progress ."% $message " if $message;
			}
		}
		sleep 3;
		if ($input->can_read(.5)) { #timeout is half a second
			chomp(my $ask = <STDIN>);
			if ($ask eq 'STOP') {
				print "Cancellation requested!\n";
				if ($task->info->cancelable) { eval {$task->CancelTask();}}
				else {print "Task cannot be canceled at this moment.\n";}
			}
		}
	}

	# note that for CheckReloate_task(), it will return "success" regardless of the check result. 
	# the actual validation result is in task->info->result;
	my $state = $task->info->state->val;
	my $color = ($state =~ m/success/i)?'bold green':'bold red';
	print ">> " . color($color).uc($state).color('reset');
	if (defined $task->info->error) { print ": " . $task->info->error->localizedMessage . "\n"; }
	else {print "\n\n";}
	
	# task->info->result:
	# clone - result holds the moref for the cloned vm
	# move - there is NO result data, but entityName holds the new vm's name
	# dryrun - result holds the validation info. Check that for failure.
	if ($dryrun && defined ($task->info->{'result'})) {
		my $result = $task->info->{'result'};

		foreach my $item (@{$result}) {
			if (defined $item->{'error'}) {
				print color('red')."#### ERROR ####". color('reset')."\n";
				foreach (@{$item->{'error'}}) {
					print $_->{'localizedMessage'} . "\n";
				}
			}
		}
	}

	#let's figure out how long it took to finish this
	#my $current = localtime();
	my $current = strftime("%Y-%m-%d %H:%M:%S", localtime);
	my $elapsed = time - $^T;
	my ($h, $m, $s) = ($elapsed/3600%24, $elapsed/60%60, $elapsed%60);

	# only provide timing information if the operation was successful and not a dryrun
	if ($state =~ m/success/i && !$dryrun) {
		
		# did we do it hot or cold, based on $power
		my $temp = ($power eq 'poweredOn')?'live':'cold';
		
		# since we are done, we might as well talk about it in past tense. Note grammatically this goes astray
		$event =~ s/$doing/$done $temp/;

		my $timeTaken = sprintf '%02d:%02d:%02d', $h,$m,$s;
		my $users = ($username eq $user2)?$username:$username.'/'.$user2;
		my $record = "$event by $users on $current [$timeTaken]";
		print color('green')."### $record\n".color('reset');

		# let's grab the vm in its new location as we are going to do something to it.
		# task->info->entity appears to be the moref of the vm BEFORE migration
		# task->info->entityName however does hold the new name, if any
		# is our session still good? Not sure. I'll just recreate it...it won't hurt.
		$dstVIM = &create_session($dstVC, $user2, $pass2);
		my $vm = ($op =~ $MOVE)? $dstVIM->find_entity_view(view_type=>'VirtualMachine', filter=>{'name'=>qr/^@{[$task->info->entityName]}$/i},
			properties=>['config.annotation','name','datastore']):
			$dstVIM->get_view(mo_ref=> $task->info->result, properties=>['config.annotation','name','datastore']);

		if (!$vm) { &cleanUp("Oops! I couldn't find the $done vm!\n"); }

		# unless it was requested to exclude the timing information in the annotation. For all cross-vm operation...
		if (! $nostamp && $xvc) {
			print color('blue')."### Stamping the VM @{[$vm->{'name'}]} with operation stats...\n".color('reset');
			my $anno = ($vm->{'config.annotation'})? $vm->{'config.annotation'}."\n* $record":"* $record";
			$anno =~ s/^\s*\n+//mg; # clean up a bit so that we don't end up with empty lines
			
			# Limited characters allowed in the annotation field. Trim it so that the latest is always recorded
			# trim from the nth line instead as the first few line might be providing some history
			$anno =~ s/^(.*\n){6}\K(.*\n){1}// if (length($anno) gt 1400);
			my $vmConfigSpec = VirtualMachineConfigSpec->new (annotation => $anno);
			$vm->ReconfigVM(spec => $vmConfigSpec);
		}

		# for migration across VC, refresh datastore for vm
		if ($xvc && $op =~ $MOVE) {
			print color('blue')."### Refresh datastore to update vm storage usage...\n".color('reset');
			&refreshVmDatastore($vm);
		}
	}
}

# we need to refresh datastore for xVC migration due to a bug
sub refreshVmDatastore() {
	my $vm_view = shift;
	my $ds_view;
	foreach my $ds (@{$vm_view->datastore}) {
		$ds_view = $dstVIM->get_view(mo_ref=>$ds, properties=>['name']);
		print "Refresh datastore " . $ds_view->{'name'} . "\n";
		$ds_view->RefreshDatastoreStorageInfo();
	}
}

sub create_session() {
        $|=1; # set/enable autoflush

        my ($server, $username, $password) = @_;
        my $sessionfile = "$ENV{HOME}/.session-$server";
        my $service_url = "https://$server/sdk";
        my $vim = Vim->new(service_url => $service_url);
        $vim->unset_logout_on_disconnect();

	# see if the session file is still valid:
        eval { $vim->load_session(session_file => $sessionfile);};
        if ($@) {
                eval {
                        local $SIG{ALRM} = sub { die "alarm\n"};
                        alarm 10;
                        $vim->login(user_name => $username, password => $password);
                        $vim->save_session(session_file => $sessionfile);
                        alarm 0;
                };
		if ($@) { print $@ . "\n";}
		else { $sessionFreshness = 'green'; }
        } else {$sessionFreshness = 'yellow';}

        # Return even if a login was unsuccessful. $vim->{'service_content'} is undef in such case.
        return $vim;
}
