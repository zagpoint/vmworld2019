#!/usr/bin/perl -w
use strict;
use warnings;
use VMware::VIRuntime;
use Sort::Naturally;
use Term::ANSIColor;
use Data::Dumper;
use feature qw(say);
use Time::HiRes qw(time);
#
##############################################
# Query vm configuration and stats           #
##############################################
# Written by: Zaigui Wang
#
my %opts = ( 
	vm => { type => "=s", help => "optional: VM name/IP/dns name). If not provided, all vms will be listed as appropriate", required => 0},
	cluster => { type => "=s", help => "optional: cluster name. Used if vm name is not provided", required => 0},
	rp => { type => "=s", help => "Resource Pool Name. Used if vm name is not provided", required => 0},
	host => { type => "=s", help => "host name. Used if vm name is not provided", required => 0},
	state => { type => "=s", help => "Optional: filter on vm connection state: inaccessible/orphaned/connected/disconnected", required => 0},
	power => { type => "=s", help => "Optional: filter on vm power state: on/off", required => 0},
	latencysensitivity => { type => "=s", help => "Optional: filter on vm latency sensitivity: high/medium/low/normal", required => 0},
	short => { type => "", help => "Optional: no vm details", required => 0},
	summary => { type => "", help => "Optional: VM summary only", required => 0},
	resource => { type => "", help => "Optional: resource allocation details only", required => 0},
	location => { type => "", help => "Optional: Location details only", required => 0},
	network => { type => "", help => "Optional: network details only", required => 0},
	storage => { type => "", help => "Optional: storage details only", required => 0},
	notes => { type => "", help => "Optional: annotation details only", required => 0},
	snapshot => { type => "", help => "Optional: snapshot details only", required => 0},
	moref => { type => "", help => "Optional: include management object ID, if any", required => 0},
);

# validate options, and connect to the server
#delete $ENV{'https_proxy'};
Opts::add_options(%opts);
Opts::parse();
my $vmname = Opts::get_option('vm');
my $clustername = Opts::get_option('cluster');
my $hostname = Opts::get_option('host');
my $rpname = Opts::get_option('rp');
my $short = Opts::option_is_set('short');
my $summary = Opts::option_is_set('summary');
my $resource = Opts::option_is_set('resource');
my $location = Opts::option_is_set('location');
my $network = Opts::option_is_set('network');
my $storage = Opts::option_is_set('storage');
my $notes = Opts::option_is_set('notes');
my $moref = Opts::option_is_set('moref');
my $state = Opts::get_option('state');
my $power = Opts::get_option('power');
my $latency = Opts::get_option('latencysensitivity');
my $snapshot = Opts::option_is_set('snapshot');
my $server = Opts::get_option('server');

#
Opts::validate();
my $username = Opts::get_option('username');
my $password = Opts::get_option('password');

# Establish a session...
my $vim = &create_session($server);
die "Failed to establish session...\n" unless (defined $vim->{'service_content'});

# build the filter. If vmname is provide, use vmname, or else, use cluster name, or if either provided, use nothing.
my @vmfilter=(filter=>{});
my @scope=();
my @vmproperty = (properties=>['name','config','resourceConfig','runtime','resourcePool','guest','value','recentTask']);
if ($vmname) {
	# what if vmname is an IP address (ipv4)? We'll deal with vmname as dns name in an extra search later
	my $isIP = ($vmname =~ m/\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}/)?1:0;
	@vmfilter = ($isIP)?(filter=>{'guest.ipAddress'=>qr/^$vmname/i}):(filter=>{name=>qr/^$vmname/i});
}
if ($hostname) {
        my $host = $vim->find_entity_view(view_type => 'HostSystem', properties => ['name'], filter=>{'name'=>qr/^$hostname/i});
        die "No host $hostname" unless ($host);
        @scope = (begin_entity => $host);
} 
if ($clustername) {
	my $cluster = $vim->find_entity_view(view_type => 'ClusterComputeResource', properties => ['name'], filter=>{'name'=>qr/^$clustername/i});
	die "No cluster $clustername" unless ($cluster);
	@scope = (begin_entity => $cluster);
} 
if ($rpname) {
	my $rp = $vim->find_entity_view(view_type => 'ResourcePool', filter=>{'name'=>qr/^$rpname$/i});
	die "No resource pool $rpname found" unless $rp;
	@scope = (begin_entity => $rp);
}

# build more filters based on command line arguments
if ($power) { $vmfilter[1]{'runtime.powerState'} = "powered".ucfirst($power);}
if ($state) { $vmfilter[1]{'runtime.connectionState'} = $state;}
if ($latency) { $vmfilter[1]{'config.latencySensitivity.level'} = $latency;}

#  Set all options UNLESS individual option(s) are specified.
my $ID = " ";
unless ($short or $summary or $resource or $location or $network or $storage or $snapshot or $notes) {
	# set these options
	Opts::set_option('short' => '');
	Opts::set_option('summary' => '');
	Opts::set_option('location' => '');
	Opts::set_option('resource' => '');
	Opts::set_option('network' => '');
	Opts::set_option('storage' => '');
	Opts::set_option('notes' => '');
	Opts::set_option('snapshot' => '');
	$ID='';
}

############### might as well get the nsx logical network inventoried early
my $opaqueNET = $vim->find_entity_views(view_type => "OpaqueNetwork", properties=>['summary']);
my $vms = $vim->find_entity_views(view_type=>'VirtualMachine',@vmfilter, @vmproperty, @scope);

# let's also find the vms with dns name as the requested vm name
if ($vmname && ! @$vms) {
	$vmfilter[1]{'guest.hostName'} = qr/^$vmname/i;
	delete $vmfilter[1]{'name'};
	$vms = $vim->find_entity_views(view_type=>'VirtualMachine',@vmfilter, @vmproperty, @scope);
}

################
if (@$vms gt 1) {print "[". @$vms . " vms]\n";}
elsif (@$vms == 1) {print "[". @$vms . " vm]\n";}
else { print "[No vm]\n";}

foreach my $vm (sort{ncmp ($a->name, $b->name)} @$vms) {
	my (%ctrlmap,@ctrls,@vmdks,@nics, $type,$diskLabel,$fileName,$diskSize, $diskBus, $diskUnit, $slot, $diskMode,$uuid, 
	    $pgname, $co, $cbt,$ip,$hotadd,$gw,$dev,$time,$tt,$tr,$tv,$ts,$tvs,$product,$vmuuid,$birthday,$fcdid, $extraConfig, $media,%hbr);
	my $vmName = $vm->{'name'};
	my $dnsName = (defined($vm->guest->{hostName}))?$vm->guest->hostName:'';
	$dnsName=~s/.vmware.com// if ($dnsName);
	if ($dnsName && (lc $vmName ne lc $dnsName)) {$vmName = color("bold red").$vmName.':'.color("bold green").$dnsName.color('reset');}

	$ID = " ($vmName)" if ($ID && ! $short);
	$vmuuid = (defined $vm->{config}->{instanceUuid})?$vm->config->{instanceUuid}:'';
	$birthday = (defined $vm->config->{'createDate'})?$vm->config->{'createDate'}:'';
	#$birthday =~ s/:\d+\.\d+//;
	$birthday =~ s/T.*Z/z/;
	$birthday = 'birth: '.$birthday if $birthday;
	#2019-03-12T05:15:51.736352Z
	
	$vm->ViewBase::update_view_data();
	my $cName = 'Not Found';
	my $ft='';
	my $ftState ='';
	my $connState = $vm->runtime->connectionState->val; 
	$connState = color("red"). $connState . color("reset") if ($connState eq 'inaccessible' || $connState eq 'orphaned'); 
	$connState .= ',' if $connState;
 	$ftState = $vm->runtime->faultToleranceState->val if defined $vm->runtime->{'faultToleranceState'};
	if (defined $vm->config->{'ftInfo'}) {$ft = ($vm->config->ftInfo->role eq 1)?" (Primary: $ftState)":" (Secondary: $ftState)";} 
	#$ft = "| $ft" if $ft;
	$cbt = ($vm->config->changeTrackingEnabled eq 0)?'Off':'On' if (defined $vm->{config}->{changeTrackingEnabled});
	$cbt = 'NA' unless (defined $cbt);

	my $hotmem = ($vm->config->memoryHotAddEnabled)?"mem/true":'mem/false';
	my $hotcpu = ($vm->config->cpuHotAddEnabled)?"cpu/true":'cpu/false';
	$hotadd = ", ACPI:$hotmem|$hotcpu";

	$extraConfig = $vm->config->{extraConfig} if (defined $vm->config->{extraConfig});
        foreach (@$extraConfig) { $hbr{$_->key} = $_->value if ($_->key =~ /^hbr_filter/); }

	(my $powerState =  $vm->runtime->powerState->val) =~ s/powered//g;
	if ($powerState eq 'On') {
		$powerState = color("green") . $powerState . color('reset');
		$time = $vm->summary->quickStats->uptimeSeconds;
		$time = ($time > 86400)?sprintf("%.f", $time/60/60/24).' days':sprintf("%.f", $time/3600).' hrs';
	} else {
		# we probably want to figure out how the vm ended up off
		$powerState = color("red") . $powerState . color('reset');

		#trying to get the poweroff event so that we know when it was powered off
		my $eventMgr = $vim->get_view(mo_ref => $vim->get_service_content()->eventManager);
		my $recursion = EventFilterSpecRecursionOption->new("self");
		my $entity = EventFilterSpecByEntity->new(entity => $vm, recursion => $recursion);
		my $filterSpec = EventFilterSpec->new(type => ["VmPoweredOffEvent", "VmGuestShutdownEvent"], entity => $entity);
		my $events = $eventMgr->QueryEvents(filter => $filterSpec);
		if (@$events) {
			foreach (@$events) {
				($time = $_->createdTime) =~ s/T.*//;
				my $user = substr($_->userName, 0, 20);
				$user =~ s/.*\\(.*)/$1/;
				$time = ($user)?"$time by $user":"$time";
				(my $event = ref($_)) =~ s/.*?(Shutdown|PoweredOff).*/$1/gi;
				$powerState = color("red") . $event . color('reset');
				last if $user;
			}
		} else { $time = '';}
	}
	# if tools not running, we miss a few things
	if (($vm->guest->guestState eq 'running') and (defined $vm->guest->ipStack)) {
		my $routes = ${$vm->guest->ipStack}[0]->{'ipRouteConfig'}->{'ipRoute'};
		foreach (@$routes) { 
			if ($_->{'network'} eq '0.0.0.0') {
				$gw = $_->gateway->{'ipAddress'};
				$dev = $_->gateway->{'device'};
			}
		}
		$gw = '0.0.0.0' unless (defined $gw);
		$ip = (defined $vm->guest->{ipAddress})?$vm->guest->{ipAddress}:'0.0.0.0';
	} else { $ip ='0.0.0.0'; $gw='0.0.0.0'; }

	# get the guest type. For an appliance, there should be a "product" designation.
	# if no product designation, then it is likely not an appliance. Get the guest os from tool if tool is running.
	# Last resort is get the name from "config", which might not be accurate.
	if (defined $vm->config->{vAppConfig}) {
		foreach (@{$vm->config->{vAppConfig}->{product}}) { 
			$product = $_->name unless (! $_->{'name'});
		}
	}
	if (!$product) {
		if ($vm->guest->guestState eq 'running') {
			$product = $vm->guest->guestFullName;
		}
	}
	if (! $product && defined $vm->config->{guestFullName}) { $product = $vm->config->{guestFullName} . '?'; }
	$product =~ s/ or later/\+/g if $product;
	$product =~ s/Microsoft //g if $product;
	$product =~ s/VMware vCenter Server Appliance/VCSA/g if $product;
	$product =~ s/SUSE Linux Enterprise/SLE/g if $product;
	$product =~ s/VMware vRealize Network Insight/vRNI/g if $product;
	$product =~ s/vSphere Replication/VR/g if $product;
	$product =~ s/Red Hat Enterprise Linux/RHEL/g if $product;
	$product =~ s/64-bit/x64/g if $product;

	my $h = $vim->get_view(mo_ref => $vm->runtime->host, properties => ['name', 'parent','config.network.portgroup','config.storageDevice.plugStoreTopology.path']); 
	# let's build a naa to device ID hash here for the array of hashes in $h->{'config.storageDevice.plugStoreTopology.path'}
	my $paths = $h->{'config.storageDevice.plugStoreTopology.path'};
	my %lunmap = map {
		if (defined $_->{'device'}) { 
			(my $naa = $_->device) =~ s/.*Device-[0-9a-z]{10}(.*)[0-9a-z]{12}/naa.$1/;
			$naa => $_->{lunNumber};
		}
	} @$paths;

	my $vOID = ($moref)?" [". $vm->{'mo_ref'}->value."]":''; 
	my $hOID = ($moref)?" [" . $h->{'mo_ref'}->value."]":'';
	my $vsspg = $h->{'config.network.portgroup'}; 
	my $c = $vim->get_view(mo_ref => $h->parent, properties => ['name','parent','value']);
	my $cOID = ($moref)?" [". $c->{'mo_ref'}->value . "]":'';

	# find out the DC here. backtrace to parents
	my $dc = $vim->get_view(mo_ref => $c->parent, properties => ['name', 'parent']);
	while (ref($dc) eq 'Folder') { 
		$dc = $vim->get_view(mo_ref => $dc->parent, properties => ['name', 'parent']);
	}
	my $dcName = $dc->{'name'};
	my $dcOID = ($moref)?" [". $dc->{'mo_ref'}->value. "]":'';
	
	# there is no resource pool defined for tempalte!
	my $r = ($vm->config->{template})?():$vim->get_view(mo_ref => $vm->resourcePool, properties => ['name']);
	my $rOID = ($r)?" [".$r->{'mo_ref'}->value."]":'';
	$rOID = '' unless $moref;
	my $rpool = ($r)?"POOL:$r->{'name'}":'POOL:n/a';

	if (ref($c) eq 'ClusterComputeResource') { $cName = $c->name; }
	my $host = $h->{'name'} =~ s/.vmware.com//r;
	
	if (defined $vm->guest->toolsStatus) {
		($ts = $vm->guest->toolsStatus->val) =~ s/tools//g;
		$ts = color('red'). $ts . color('reset') if ($ts =~ m/(Not|Old)/);
		$ts = color('green'). $ts . color('reset') if ($ts eq 'Ok');
		($tr = $vm->guest->toolsRunningStatus) =~ s/guestTools//g;
		$tr = color('red'). $tr . color('reset') if ($tr =~ m/Not/);
		$tr = color('green'). $tr . color('reset') if ($tr eq 'Running');
		$tr = '' if ($ts eq $tr);
		$tv = $vm->guest->toolsVersion; 
		foreach (@$extraConfig) { $tvs = $_->value if ($_->key eq 'guestinfo.vmtools.versionString');}
		$tv = $tv . '-' . $tvs if $tvs;
		$tv='unknown' unless (defined $tv);
	} else { $ts = $tr = $tv = ''; }

	# basic information
	if (Opts::option_is_set('short')) {
		#print "$vmName".color("cyan"). "$vOID $ft | $ip | $host$hOID | $cName$cOID | $dcName$dcOID | $server".color('reset')." ($connState $powerState $time, $birthday)\n";
		print "$vmName$vOID$ft | $ip | $host$hOID | $cName$cOID | $dcName$dcOID | $server ($connState $powerState $time, $birthday)\n";
	}	
	if (Opts::option_is_set('summary')) {
		my $latency = color('red').'unset'.color('reset');

		# pervm EVC: vm->capability->perVmEvcSupported is true for vmx-14+
		my $evcmode = (defined $vm->{runtime}->{minRequiredEVCModeKey} && $vm->capability->perVmEvcSupported)?
				", ".color('red')."EVC:".$vm->{runtime}->{minRequiredEVCModeKey}.color('reset'):'';
		if (defined $vm->config->latencySensitivity) {
			$latency = ($vm->config->latencySensitivity->level->val eq 'normal')?color('bold green').$vm->config->latencySensitivity->level->val.color('reset'):
			color('red').$vm->config->latencySensitivity->level->val.color('reset');
		}
		my $version = $vm->config->version;
		$version = color('red') . $version . color('reset') if ($version lt 'vmx-14');
		print " Summary: $product, Tools:$ts ($tr $tv), CBT:$cbt, Sensitivity:$latency, HW:$version$hotadd$evcmode$ID\n"; 
	}

	# Location
	if (Opts::option_is_set('location')) {
		my $folderView= $vim->get_view(mo_ref=> $vm->parent) if defined $vm->parent;
		my $fOID = " [". $folderView->{'mo_ref'}->{'value'} . "]";
		$fOID = '' unless $moref;
		my $folderName = $folderView->name; 
		print "Location: $rpool$rOID, FOLDER:$folderName$fOID, VMX:" . $vm->config->files->vmPathName. "$ID\n";
	}

	##### HARDWARE 
	if (Opts::option_is_set('resource')) {
		my $activeMem = $vm->summary->quickStats->guestMemoryUsage;
		my $hostMem = $vm->summary->quickStats->hostMemoryUsage;
		my $overallCpu = $vm->summary->quickStats->overallCpuUsage;
		$activeMem = ($activeMem)?", Active: ${activeMem}MB":'';
		$hostMem = ($hostMem)?", Allocated: ${hostMem}MB":'';
		$overallCpu = ($overallCpu)?", Usage: ${overallCpu}MHz":'';
		my $CPUalloc = $vm->resourceConfig->cpuAllocation;
		my $MEMalloc = $vm->resourceConfig->memoryAllocation;
		my $nCPU = $vm->config->hardware->numCPU;

		# virtual core was not supported until later hardware version
		my $nCore = (defined $vm->config->hardware->numCoresPerSocket)? $vm->config->hardware->numCoresPerSocket:1;
		my $nSock = $nCPU/$nCore;
		my $ushare = $CPUalloc->shares->level->val . ':' . $CPUalloc->shares->shares;
		$ushare = ($ushare =~ /normal/i)?color('bold green').$ushare.color('reset'):color('bold red').$ushare.color('reset');
		my $ulimit = ($CPUalloc->limit eq '-1')?'unlimited':color('bold red').'Limit: '.color('reset').$CPUalloc->limit;
		my $ures = ($CPUalloc->reservation eq '0')?'unreserved':$CPUalloc->reservation .'MHz'. color('bold red')." reserved".color('reset');
		my $mlimit = ($MEMalloc->limit eq '-1')?'unlimited':color('bold red').'Limit: '.color('reset').$MEMalloc->limit;
		my $mres = ($MEMalloc->reservation eq '0')?'unreserved':$MEMalloc->reservation .'MB'.color('bold red'). " reserved".color('reset');
		my $mshare = $MEMalloc->shares->level->val . ':' . $MEMalloc->shares->shares;
		$mshare = ($mshare =~ /normal/i)?color('bold green').$mshare.color('reset'):color('bold red').$mshare.color('reset');
		
		# storage could be missing, or incorrect after x-VC migration: https://bugzilla.eng.vmware.com/process_bug.cgi
		my ($committed, $uncommitted, $unshared) = (0,0,0);
		if (defined $vm->summary->{'storage'}) {
			$committed = sprintf("%.f", $vm->summary->storage->committed /1024**3);
			$uncommitted = sprintf("%.f", $vm->summary->storage->uncommitted /1024**3);
			$unshared = sprintf("%.f", $vm->summary->storage->unshared /1024**3);
		}
		print "Resource: $nCPU [".$nSock ."x".$nCore . "] vCPU ($ushare, $ulimit, $ures$overallCpu)\n" . "          ". $vm->config->hardware->memoryMB.
			"MB Memory ($mshare, $mlimit, $mres$hostMem$activeMem)\n"."          ${committed}GB disk committed (${uncommitted}GB uncomitted, ${unshared}GB unshared)$ID\n";
	}

	if (Opts::option_is_set('network') or Opts::option_is_set('storage')) {
		my $devices = $vm->config->hardware->device;
		foreach (sort {$a->key cmp $b->key} @$devices) {
			if ($_->isa('VirtualSCSIController')) { push (@ctrls, $_);}
			if ($_->isa('VirtualEthernetCard')) { push (@nics, $_);}
			if ($_->isa('VirtualDisk')) {push (@vmdks, $_); }
			if ($_->isa('VirtualCdrom')) {
				if ($_->connectable->connected) {
					if (defined $_->{backing}->{filename}) { $media = $_->backing->fileName;}
					else {$media = 'UNKNOWN';}
				}
			}
		}
	}

	# Getting NIC information. How about take an educated guess of vlan of the portgroup?
	# Granted not all portgroups are vlan tagged (in the case of guest side tagging - VGT)...
	if (Opts::option_is_set('network')) {
		print " Network: "; 
		my $spacer = '';
		foreach my $nic (sort {$a->key cmp $b->key} @nics) {
			my $IP = '0.0.0.0';
			my $switch = 'Unknown';
			my $vlanId ='';

			#vDS
			if (ref($nic->backing) eq 'VirtualEthernetCardDistributedVirtualPortBackingInfo') {
				my $pkey = $nic->backing->port->portKey; 
				my $dvkey = $nic->backing->port->portgroupKey;
				my $vdspg = $vim->find_entity_view(view_type=>"DistributedVirtualPortgroup", properties=>['name','key','config'], filter=>{key=>$dvkey});
				if ($vdspg) {
					if (ref ($vdspg->{'config'}->defaultPortConfig->vlan->vlanId) eq 'ARRAY') { $vlanId = 'trunk'; }
					else { $vlanId = $vdspg->{'config'}->defaultPortConfig->vlan->vlanId; }	
					($pgname = $vdspg->name)  =~ s;%2f;/;g;;
					$switch = $vim->get_view(mo_ref => $vdspg->config->distributedVirtualSwitch, properties => ['name']);
					$switch = ($moref)?$switch->name."[".$switch->{'mo_ref'}->value."]":$switch->name;
				} else {
					$pgname = '';
					$switch = 'Network-Unavailable';
				}
			}
			
			#vSS
			elsif (ref($nic->backing) eq 'VirtualEthernetCardNetworkBackingInfo') { 
				($pgname = $nic->backing->deviceName) =~ s;%2f;/;g;
				foreach (@$vsspg) {
					if ($_->key =~ m/$pgname/) {
						$switch = $_->{spec}->{vswitchName};
						$vlanId = $_->{spec}->{vlanId};
					}
				}
			}

			# NSS nvds: this is external network, aka opaque network, provided by NSX-T for example
			elsif (ref($nic->backing) eq 'VirtualEthernetCardOpaqueNetworkBackingInfo') {
				my $opaqueNetworkId = $nic->backing->opaqueNetworkId;
				foreach (@$opaqueNET) {
					if ($_->summary->opaqueNetworkId eq $opaqueNetworkId) {
						$switch = color("bold black").$_->summary->opaqueNetworkType.color('reset');
						$pgname = $_->summary->name . " (" . $_->summary->network->value . ")";
						last;
					}
				}
			}

			(my $nictype = lc ref($nic)) =~ s/virtual//g;
			(my $NIC = $nic->deviceInfo->label) =~ s/\D//g;
			my $conn = ($nic->connectable->connected)?"connected":"disconnected";
			my $tofro = ($nic->connectable->connected)?"to":"from";
		
			if (($vm->guest->guestState eq 'running') and (defined $vm->guest->net)) {
				foreach(@{$vm->guest->net}) { 
					if ($_->deviceConfigId eq $nic->key) {
						if (defined $_->ipAddress && defined $_->ipConfig) {
							my $addr = $_->ipConfig->ipAddress;
							foreach $ip (@$addr) {
								if ($ip->ipAddress =~ /\./) {
									$IP = ${$addr}[0]->ipAddress.'/'.${$addr}[0]->prefixLength;
									last;
								}
								else {next;}
							}	       
						}
					}
				}
			}

			$co = ($nic->connectable->connected)? "green":"red";
			$vlanId = ' [vlan:'.$vlanId.']' if $vlanId;
			print $spacer."NIC #".$NIC." (". $nic->key. "), ".$nictype." (".$nic->macAddress."|$IP|$gw) ".color("bold $co").$conn.color('reset')." $tofro ${switch}::$pgname$vlanId$ID\n";
			$spacer = '          ';
		}
		print "No network assigned\n" unless @nics;
	}

	# controller information
	if (Opts::option_is_set('storage')) {
		print $ID . "\n" if $ID;
		print " Storage: " if (@ctrls); 
		my $spacer = '';
		foreach (@ctrls) {
			(my $ctrl = $_->deviceInfo->label) =~ s/\D//g;		
			$ctrlmap{$_->key} = $ctrl;
			$co = ($_->sharedBus->val eq 'noSharing')?"green":"red";
			print "${spacer}Controller #".$ctrl . " - ".$_->key. ", ".$_->deviceInfo->summary. " [" . color("bold $co").$_->sharedBus->val.color('reset') ."]\n";
			$spacer = '	  ';
		}

		# getting disk information
		my $Unit = 'GB';
		my ($sharing, $sh_note, $linkedclone, $lc_note, $base) = ('') x 5;

		next unless (@vmdks);
		foreach (sort {(split(/ /, $a->deviceInfo->label))[2] <=> (split(/ /, $b->deviceInfo->label))[2]} @vmdks) {
			if (defined $_->backing->sharing) {
				$sharing = ($_->backing->sharing eq 'sharingMultiWriter')?color('bold red').' *'.color('reset'):'';
				$sh_note =color('bold red').'*'.color('reset')." indicates disk shared via vmdk multi-writer." if ($_->backing->sharing eq 'sharingMultiWriter');
			} 
			if (defined $_->backing->parent) {
				my $backing = $_->backing->parent;
				while (defined $backing->parent) { $backing = $backing->parent; }
				$base = $backing->fileName;
				$linkedclone = color('bold red'). sprintf "\x{21b0}". color('reset');
				$lc_note = $linkedclone ." indicates snapshot/linked clone disk (base disk shown along).";
			} else { $linkedclone = ''; }

			($diskLabel = $_->deviceInfo->label) =~ s/\D//g; # this will get you the disk #
			$diskLabel = sprintf("%02d", $diskLabel);
			# 
			my $IOlimit = $_->storageIOAllocation->limit;

			# Assuming vmfs here. This might break in vsan.
			my $naa = '';
			my $ds = $vim->get_view(mo_ref=>$_->backing->datastore, properties => ['info','summary']);

			if ($ds->summary->type eq 'VMFS') {
				$naa = ${$ds->info->vmfs->extent}[0]->diskName;

				# try to get the real naa if there is rdm involved here. lunUuid is a sure sign
				if (defined $_->backing->{'lunUuid'}) {
					($naa = $_->backing->lunUuid) =~ s/[0-9a-z]{10}(.*)[0-9a-z]{12}/naa.$1/;
				}
			}

			my $nlen = 2;
			$nlen += length $naa if $naa;

			($fileName, $diskSize) = ($_->backing->fileName, sprintf("%.f", ($_->capacityInKB)/1024**2));
			if ($diskSize > 1024) { 
				$diskSize = sprintf("%.1f", $diskSize/1024); $Unit='TB';
			} else {$Unit = "GB"; }

			($diskBus, $diskUnit) = ($ctrlmap{$_->controllerKey}, $_->unitNumber);
			$slot = $diskBus . ":" . $diskUnit;
			($diskMode = $_->backing->diskMode) =~ s/.{13}\K.*//s;

			#Physical RDM does not have uuid. It has lunUuid. we need to extrac the uuid from it.
			if (defined ($_->backing->{'uuid'})) {
				($uuid = $_->backing->{'uuid'}) =~ s/-//g;
			} elsif ($_->backing->{'lunUuid'}) {
				($uuid = $_->backing->{'lunUuid'}) =~ s/.{10}(.*).{12}/$1/;
			} else { $uuid = 'n/a';}

			if($_->backing->isa('VirtualDiskFlatVer2BackingInfo')) {
				if ($_->backing->thinProvisioned) { $type = "Thin"; } 
				elsif ($_->backing->eagerlyScrub) { $type = "EZT"; } 
				else { $type = "LZT"; }
			}

			# let me also catch FCD virtual disk ID if any:
			if (defined $_->{'vDiskId'}) { $fcdid = "(FCD/". $_->vDiskId->id. ")"; }
			else {$fcdid ='';}

			if($_->backing->isa('VirtualDiskRawDiskMappingVer1BackingInfo')) { $type = ($_->backing->compatibilityMode eq 'physicalMode')? 'pRDM': 'vRDM'; }
			my $hostID = ($type eq 'pRDM' or $type eq 'vRDM')?' (L'. $lunmap{$naa}.')':'';
			#printf "%-03s%5s %-5s%-15s%6s %32s %${nlen}s %-50s\n", "#".$diskLabel, $slot, $type, $diskMode,$diskSize.$Unit, lc($uuid),$naa,$fileName.$hostID.$sharing.$linkedclone;
			printf "%12s%5s %-5s%-15s%6s %32s %${nlen}s %-50s\n", $diskLabel, $slot, $type, $diskMode,$diskSize.$Unit, lc($uuid),$naa,$fileName.$hostID.$sharing.$linkedclone;
			#printf "%78s%50s\n", ' ', $base . " $fcdid" if ($linkedclone);
			print "          					$base $fcdid\n" if ($linkedclone);
		}
		print "          " . colored("$sh_note\n", "green") if ($sh_note);
		print colored("$lc_note\n", "green") if ($lc_note);
	}

	# snapshot
	if (Opts::option_is_set('snapshot')) {
		# get snapshot information if present
		if (defined $vm->snapshot) {
			print color("bold red"). "Snapshot: ". color('reset');
			my $rootsnap = $vm->snapshot->rootSnapshotList;
			print ${$rootsnap}[0]->name .' ('. ${$rootsnap}[0]->snapshot->value.') ['. ${$rootsnap}[0]->createTime.'] ';
			if (defined ${$rootsnap}[0]->childSnapshotList) {
				my $childlist = ${$rootsnap}[0]->childSnapshotList; 
				while ($childlist) {
					print " => ". ${$childlist}[0]->name .' ('.${$childlist}[0]->snapshot->value .')['. ${$childlist}[0]->createTime.'] ';
					if (defined ${$childlist}[0]->childSnapshotList) { $childlist = ${$childlist}[0]->childSnapshotList;
					} else { undef $childlist; }
				}
			}
			print "$ID\n";
		}
	}

	# if there is any custom field, list them here. Need to get the key label
	if (Opts::option_is_set('notes')) {
		my $len = 0;
		if ($vm->config->annotation) {
			my $anno = $vm->config->annotation;
			$anno =~ s/^\s*\n+//mg;
			print color('cyan')."$anno\n".color('reset');
		}

		if (defined $vm->value) {
			my $customfieldMgr = $vim->get_view(mo_ref => $vim->get_service_content()->customFieldsManager);
			my %customkeys;
			
			#create the custom fields key mapping
			foreach (@{$customfieldMgr->field}) { $customkeys{$_->key} = $_->name; }

			# get the max len for values so that we can print out accordingly
			foreach(@{$vm->value}) {
				$len = length $customkeys{$_->key} if (length $customkeys{$_->key} > $len);
			}
			foreach(@{$vm->value}) {
				print colored(sprintf("%-${len}s: %-20s\n", $customkeys{$_->key}, $_->value), 'cyan');
			}
		}
		if (defined($vm->config->managedBy)) {
			my $mb = $vm->config->managedBy->type;
			print colored(sprintf("%-${len}s: %-20s\n", 'managedBy Type', $mb), 'cyan');
		}
		if (%hbr) { foreach my $key (sort keys %hbr) { 
				my $val = $hbr{$key};
				$key =~ s/hbr_filter/VR/;
				print colored(sprintf ("%-23s: %-20s\n", $key, $val),'cyan');}
		}
		if ($media) { print color('red'). "** CDROM connected to $media\n".color('reset');}

		if (defined($vm->recentTask)) {
			my $taskMan = $vim->get_view(mo_ref=>${$vim->get_service_content()}{taskManager});
			foreach my $vmtask (@{$vm->recentTask}) {
				foreach my $task (@{$taskMan->recentTask}) {
					if ($vmtask->value eq $task->value) {
						my $task_view = $vim->get_view(mo_ref=>$task, properties=>['info']);
						my $info = $task_view->{info};
						my $u = (defined $info->{reason}->{userName})?$info->{reason}->{userName}:'unknown-user';
						my $taskID = $info->key;
						my $desc = (defined $info->{name})?$info->name:$info->{descriptionId};
						if ($info->state->val eq 'success') {
							(my $time1 = $info->startTime) =~ s/\.\d+Z/Z/g;
							(my $time2 = $info->completeTime) =~ s/\.\d+Z/Z/g;
							print color('red') . "[$taskID] $desc by $u, started $time1, completed $time2". color('reset')."\n";
						}
						if ($info->state->val eq 'error') {
							my $error = (defined $info->{error})?': '.$info->{error}->{localizedMessage}:': unknown error';
							print color('red') . "[$taskID] $desc by $u failed".$error.color('reset')."\n";
						}
						if ($info->state->val eq 'running') {
							my $percent = $info->progress;
							my $message = (defined $info->{description})?$info->description->message:$desc;
							(my $time1 = $info->startTime) =~ s/\.\d+Z/Z/g;
							print color('red')."[$taskID] $desc [". $message."] $percent%, by $u, started $time1".color('reset')."\n";
						}
					}
				}
			}
		}
	}
}

### Function definitions ####
sub create_session() {
        $|=1; # autoflush
	my $start = time;
        my $timeout = 10;
        my ($server) = @_;
	$server .= '.vmware.com' unless ($server =~ /\.vmware\.com/ || $server =~ /\d+\.\d+\.\d+\.\d+/);
        my $sessionfile = "$ENV{HOME}/.session-$server";
        my $service_url = "https://$server/sdk";

        my $vim = Vim->new(service_url => $service_url);
        $vim->unset_logout_on_disconnect();

        eval { $vim->load_session(session_file => $sessionfile);};
        my $error = $@;
        if ($error) {
                eval {
                        local $SIG{ALRM} = sub { die "alarm";};
                        alarm $timeout;
                        $vim->login(user_name => $username, password => $password);
                        $vim->save_session(session_file => $sessionfile);
                        alarm 0;
                };

                # GREEN for new, YELLOW for re-use, and RED for bad connection
                if (not $@) {print "\n".color('green') . "[$username\@$server]" . color('reset');}
                else { print "\n".color('red') . "[$username\@$server]: $@" . color('reset');}
        } else { print "\n".color('yellow') . "[$username\@$server]" . color('reset'); }

        # Return even if a login was unsuccessful. $vim->{'service_content'} is undef in such case.
	my $elapsed = sprintf("%.f", time - $start);
        print "(${elapsed}s) " ;
        return $vim;
}
