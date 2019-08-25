#!/usr/bin/perl -w
use strict;
use warnings;
use VMware::VIRuntime;
use Term::ANSIColor;
use Data::Dumper;
##############################################
# Query vm configuration and stats           #
##############################################
# Written by: Zaigui Wang
#
#list-network.pl -vm bubble-test1 -server drvc-prod-1 |sort -k1,1 -k2,2n
# grep -o '[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}'
# grep -o '[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\/[1-9]\{2\}'
#
# 1/7/2018: added host option to display networks available to that specific host.
#
my %opts = (
	vxlanonly => { type => "", help => "including only vxlan", required => 0},
	showvm => { type=>"", help => "Optional: show vms attached to the network.", required=>0},
	nohead => { type=>"", help => "Optional: network without header title.", required=>0},
	network => { type=>"=s", help => "Optional: Names of network pg, separated by comma", required=>0},
	host => { type=>"=s", help => "Optional: Names of host", required=>0},
	vlan => { type=>"=s", help => "Optional: VLAN IDs. Separated by comma", required=>0},
);


# validate options, and connect to the server
delete $ENV{'https_proxy'};
Opts::add_options(%opts);
Opts::parse();
Opts::validate();
my $domain = 'vmware.com';
my $vxlanonly = Opts::option_is_set('vxlanonly');
my $showvm = Opts::option_is_set("showvm");
my $nohead = Opts::option_is_set("nohead");
my $server = Opts::get_option('server');
my $network = Opts::get_option('network'); $network =~ s/,/|/g if $network;
my $vlan_string = Opts::get_option('vlan'); 
my $host = Opts::get_option('host'); 
my %vlans = map {$_ => 1} split(',', $vlan_string) if ($vlan_string);
my $username = Opts::get_option('username');
my $password = Opts::get_option('password');
my $vim = &create_session($server);
die "Failed to establish session...\n" unless (defined $vim->{'service_content'});

my ($type, $hv, $nv, $netName, $netRef, $vlan,$folder,$parent,$fn, $uplink, $active, $standby, $policy, %uplinks, $switchName,@filter);
@filter = ($vxlanonly)?(filter=>{name=>qr/(virtual|universal)wire/}):();
@filter = (filter=>{'summary.name'=>qr/($network|DVUplinks)/i}) if $network;
my $networks = $vim->find_entity_views(view_type => "Network", @filter);

# Need to process dvuplinks first so that we have a proper uplink to NIC mapping.
# delete the dvuplinks element as we go (so that they don't show up again in our second pass for regular portgroups)
# processing backward so that we don't end up on an index that was deleted
for my $index (reverse 0 .. scalar(@$networks)-1) {
	my $net = @{$networks}[$index];
	($netName = $net->summary->name) =~ s;%2f;/;g; #fix the netName name where / is display as %2f

	if ($netName =~ m/DVUplinks/) {; 
		# figuring out vds uplinks. This needs to go to host and look up the proxyswitch (the dvs host components).
		if (defined $net->host) {
			foreach (@{$net->host}) {
				$hv = $vim->get_view(mo_ref => $_, properties=>['configManager.networkSystem','runtime.inMaintenanceMode']);
				if ($hv->{'runtime.inMaintenanceMode'} eq  'false') {last};
			}
			next unless (defined $hv); # if no host was found to be able to provide proxyswitch info, then process next network
			
			$nv = $vim->get_view(mo_ref => $hv->{'configManager.networkSystem'}, properties =>['networkInfo.proxySwitch']);
			$switchName = ${$nv->{'networkInfo.proxySwitch'}}[0]->dvsName if (defined $nv->{'networkInfo.proxySwitch'});
			my $pnic = ${$nv->{'networkInfo.proxySwitch'}}[0]->spec->backing->pnicSpec if (defined $nv->{'networkInfo.proxySwitch'});
			foreach (@{$pnic}) {
				foreach my $port (@{${$nv->{'networkInfo.proxySwitch'}}[0]->uplinkPort}) {
					if ($port->key eq $_->uplinkPortKey) { $uplinks{$switchName}{$port->value} = $_->pnicDevice;}
				} 
			}
		}
		splice (@$networks, $index, 1);
	}
}

# try to be smart about the portgroup label width
my $numPG = scalar @$networks;
my $width = 0;
foreach (@$networks) { 
	my $len = length($_->name);
	$width = $len if $len > $width;
}

my ($host_ref, $host_view);
if ($host) {
	$host_view = $vim->find_entity_view(view_type => 'HostSystem', properties => ['name'], filter=>{'name'=>qr/^$host/i});
	$host_ref = $host_view->{mo_ref}->{value} if $host_view;
}

$width += 1;
if (!$nohead) {
	my $scope = ($host_ref)?$server.'::'.$host:$server;
	print color("bold blue") . "# $scope #\n". color('reset');
	printf "%-${width}s%-15s%-6s%-6s%-7s%-25s%-50s%-30s\n", 'Portgroup ('.$numPG.')','mo_ref', 'NumVM', 'Type','VLAN','Teaming Policy', 'Active'. color('blue').'-Standby'.color('reset'), 'Virtual Switch';
	printf "%-${width}s%-15s%-6s%-6s%-7s%-25s%-40s%-30s\n", '---------------','------','-----','----','----', '--------------', '-----------------', '--------------';
}

###
foreach my $net (sort {$a->name cmp $b->name}@$networks) {
	$active='';
	$standby='';
	$vlan = '';
	$policy = '';

	# skip network 'none'. In some case, for example an vshield edge might have many vnics and most of which are connected to 'none'
	next if ($net->name eq 'none');

	# skip network unless the specified host has it.
	if ($host_ref && $net->host) { next unless grep { $host_ref eq $_->{value} } @{$net->host}; }
	
	# vDS: DistributedVirtualPortgroup
	# vSS: Network
	# NSX: OpaqueNetwork
	$type = ($net->summary->network->type eq 'Network')?'vSS':($net->summary->network->type eq 'OpaqueNetwork')?'nVDS':'vDS';
	($netName = $net->summary->name) =~ s;%2f;/;g; #fix the netName name where / is display as %2f
	$netRef = $net->summary->network->{'value'};

	if ($type eq 'vDS') {
		$switchName = ${$vim->get_view(mo_ref => $net->{'config'}->distributedVirtualSwitch, properties => ['name'])}{'name'};
		$vlan = $net->{'config'}->defaultPortConfig->vlan->vlanId;
		$vlan = ${$vlan}[0]{'start'}.":". ${$vlan}[0]{'end'} if  (ref $vlan eq 'ARRAY');
		$uplink = $net->{'config'}->defaultPortConfig->uplinkTeamingPolicy->uplinkPortOrder;
		$policy = $net->{'config'}->defaultPortConfig->uplinkTeamingPolicy->policy->value;
		
		if (defined $uplink->activeUplinkPort) {
			foreach (@{$uplink->activeUplinkPort}) {
				# possible there the hash does not have the uplink to NIC mapping because a vds has no host added
				#in 6.0 it is called 'Uplink x', but in 5.5, this is 'dvUplinkx'
				(my $num = $_) =~ s/d?v?Uplink\s?/#/; 
				if ($uplinks{$switchName}{$_}) {
					$active = ($active)?
					$active." ". $num.':'.$uplinks{$switchName}{$_}:$num.':'.$uplinks{$switchName}{$_}; 
				} elsif (my @keys = grep {/lag/} keys %{$uplinks{$switchName}}) { # dealing with lag
					foreach my $k (@keys) { $active = ($active)?  $active." ". $k.':'.$uplinks{$switchName}{$k}:$k.':'.$uplinks{$switchName}{$k};}
				} else { 
					$active = ($active)?$active." ". $num.':':$num.':'; 
				}
			}
		} 
		if (defined $uplink->standbyUplinkPort) {
			foreach (@{$uplink->standbyUplinkPort}) {
				(my $num = $_) =~ s/d?v?Uplink\s?/#/; 
				if ($uplinks{$switchName}{$_}) {
					$standby = ($standby)?
					$standby." ".$num.':'.$uplinks{$switchName}{$_}:$num.':'.$uplinks{$switchName}{$_}; 
				} else {
					$standby = ($standby)?$standby." ".$num.':':$num.':'; 
				}
			}
		}
	}

	#The other type of vswitch is vSS
	elsif ($type eq 'vSS') { 
		if (defined $net->host) {
			$hv = $vim->get_view(mo_ref => @{$net->host}[0], properties=>['name','configManager.networkSystem']);
			$nv = $vim->get_view(mo_ref=>$hv->{'configManager.networkSystem'});
			
			next unless (defined $nv->networkInfo);
			foreach my $pg (@{$nv->networkInfo->portgroup}) {
				if  ($netName eq $pg->spec->name) {
					$uplink=$pg->computedPolicy->nicTeaming->nicOrder;
					(my $host = $hv->name) =~ s/-\w+.$domain//;
					$switchName = $pg->spec->vswitchName.':'.$host;
					$vlan = $pg->spec->vlanId;
					$policy = $pg->computedPolicy->nicTeaming->policy;
				}
			}
			if ($uplink) {
				$active = join(' ', @{$uplink->{'activeNic'}}) if (defined $uplink->{'activeNic'});
				$standby = join(' ', @{$uplink->{'standbyNic'}}) if (defined $uplink->{'standbyNic'});
			}
		}
	}

	# or Opaque networks
	else {
		$vlan = 'opaque';
		$policy = 'opaque';
		$switchName = $net->summary->opaqueNetworkId;
	}

	$folder = $vim->get_view(mo_ref=> $net->parent);
	$parent = $vim->get_view(mo_ref=> $folder->parent);
	$fn = $folder->name;
	$standby = ' '. $standby if $standby;

	# print out vms on the network, if any
	my $vmlist = (defined $net->vm)?$net->vm:();
	my $numVm = ($vmlist)?@$vmlist:0;

	# now print out the network information.
	print $netName ."\n" unless $switchName;
	if (%vlans && ! $vlans{$vlan}) { next;}
	else { printf "%-${width}s%-15s%6d%-6s%-7s%-25s%-55s%-30s\n", $netName, $netRef, $numVm, ' '.$type, $vlan, $policy, color('green'). $active . color('blue') .  $standby. color('reset'),$switchName;}

	### what type of VMs are we looking for? ON/OFF/ALL
	if ($vmlist && $showvm) {
		my $vms = $vim->get_views (mo_ref_array => $vmlist, properties => ['name','runtime.powerState','config.hardware','summary.storage.committed']);
		foreach (@$vms) {
			my $LED=($_->{'runtime.powerState'}->val eq "poweredOn")?"\x{26ab}":"\x{26aa}";
			my $nCPU = $_->{'config.hardware'}->numCPU;
			my $aMEM = $_->{'config.hardware'}->memoryMB;
			my $cDISK = sprintf("%.f", $_->{'summary.storage.committed'}/1024**3); #disk commit in GB
			printf "\t%-2s%-40s%15s%3d%7d%15d\n", $LED, $_->name, $server, $nCPU, $aMEM, $cDISK;
		}
	}
}
print "\n";
### Function definitions ####
sub create_session() {
        $|=1; # autoflush
        my $start = time;
        my $timeout = 10;
        my ($server) = @_;
	unless ($server =~ /\.$domain/ || $server =~ /\d+\.\d+\.\d+\.\d+/) {$server .= '.' . $domain;}
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
                if ($@) { print "\n".color('red') . "[$server]: $@\n" . color('reset');}
        }
        return $vim;
}
