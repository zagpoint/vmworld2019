#!/usr/bin/perl -w
use strict;
use warnings;
use Switch;
use VMware::VILib;
use VMware::VIRuntime;
use Data::Dumper;
use Term::ANSIColor;
use Sort::Naturally; # ncmp
use feature qw(say);

# validate options, and connect to the server
my %opts = ( host => { type => "=s", help => "host name", required => 1});
Opts::add_options(%opts);
Opts::parse();
Opts::validate();

###
my $hostname = Opts::get_option('host');
my $server = Opts::get_option('server');
my $username = Opts::get_option('username');
my $password = Opts::get_option('password');

# Establish a session...
my $vim = &create_session($server);
die "Failed to establish session...\n" unless (defined $vim->{'service_content'});

# also need to capture any host that are not part of a cluster (with parent type: ClusterComputeResource and value as 'domain-xxx')
my $hosts = $vim->find_entity_views(view_type => 'HostSystem', filter=> {'name' => qr/$hostname/});
die "Host not found.\n" unless @$hosts;

foreach (sort{$a->name cmp $b->name} @$hosts) { 
	print color('blue') . $_->name . color('reset') . "\n";
	my %vmnics;
	foreach (@{$_->config->network->pnic}) { 
		$vmnics{$_->device}{'driver'} = $_->driver;
		$vmnics{$_->device}{'mac'} = $_->mac;
		$vmnics{$_->device}{'key'} = $_->key;
		$vmnics{$_->device}{'link'} = (defined $_->linkSpeed)?'connected':"nolink";
	}

	my $hostnet = $_->network;
	my $configNet = $vim->get_view(mo_ref=>$_->configManager->networkSystem);

	# find out what each vnic is for. Put service type into an array: vmk0 -> [vmotion, management]
	my $vnicmanager = $vim->get_view(mo_ref=>$_->configManager->virtualNicManager, properties => ['info.netConfig']);
	my %vnics;
	foreach (@{$vnicmanager->{'info.netConfig'}}) {
		if (defined $_->selectedVnic) {
			foreach my $selected (@{$_->selectedVnic}) {
				if (my ($item) = grep {$_->key eq $selected} @{$_->candidateVnic}) {
					if ($vnics{$item->device}) { push @{$vnics{$item->device}},$_->nicType; } 
					else { $vnics{$item->device} = [$_->nicType];}
				}
			}
		}
	}

	#print Dumper $vnicmanager->{'info.netConfig'};
	my $hints = $configNet->QueryNetworkHint(device => [map {$_->device} @{$_->config->network->pnic}]);
	
	# print out vmnic information
	print "[Physical Adapters]\n";
	foreach my $hint (sort {ncmp($a->device,$b->device)} @$hints) {
		my $vmnic = $hint->device;
		next if $vmnic =~ /vusb/;
		my $driver = $vmnics{$hint->device}{'driver'};
		my $mac = $vmnics{$hint->device}{'mac'};
		my $link = $vmnics{$hint->device}{'link'};

		# cdp and lldp will come via different objects:
		my ($switch, $port) = ('','');
		if (defined $hint->connectedSwitchPort) {
			$switch = $hint->connectedSwitchPort->systemName;
			$port = $hint->connectedSwitchPort->portId;
		} elsif (defined $hint->lldpInfo) {
			$port = $hint->lldpInfo->portId;
			my ($temp) = grep {$_->key eq "System Name"} @{$hint->lldpInfo->parameter};
			($switch = $temp->{'value'}) =~ s/.vmware.com//; 
		}
		my $connection = ($switch && $port)?$switch.'::'.$port:'';
		printf "\t%-10s%-10s%-20s%-12s%-30s\n", $vmnic, $driver, $mac, $link, ($switch && $port)?$switch.'::'.$port:'';

		# only if needed
		my @ranges; #https://stackoverflow.com/questions/45948007/perl-find-ranges-of-numbers-in-an-array
		if (defined $hint->subnet) {
			foreach (sort {$a->vlanId<=>$b->vlanId} @{$hint->subnet}) {
				if (@ranges && $_->vlanId==$ranges[-1][1]+1) {++$ranges[-1][1]; }
				else { push @ranges, [$_->vlanId, $_->vlanId]; }
			}
			#say join ',', map { $_->[0] == $_->[1] ? $_->[0] : "$_->[0]-$_->[1]" } @ranges;
		}
	}

	# print out vnic information
	print "\n[vmkernel Interfaces]\n";
	foreach (@{$configNet->networkConfig->vnic}) {
		my $vnic = $_->device;
		my $services = ($vnics{$vnic})?join(',', @{$vnics{$vnic}}):'';
		my ($mtu,$mac,$ip,$mask,$instkey) = ($_->spec->mtu,$_->spec->mac,$_->spec->ip->ipAddress,$_->spec->ip->subnetMask,$_->spec->netStackInstanceKey);
		my $gw = (defined $_->spec->ipRouteSpec)?$_->spec->ipRouteSpec->ipRouteConfig->defaultGateway:'';
		printf "\t%-6s%-6s%-20s%-16s%-16s%-16s%-20s%-20s\n", $vnic, $mtu, $mac, $ip, $mask, $gw, $instkey,$services;
	}
	# opaque switches will also have vmkernel interfce for vtep
	if (defined $_->config->network->opaqueSwitch) {
		my $opaquesw = $_->config->network->opaqueSwitch;
		foreach (@{$opaquesw}) {
			if (defined $_->vtep) {
				foreach my $vtep (@{$_->vtep}) {
					my ($vnic,$mtu,$mac,$ip,$mask) = ($vtep->device,$vtep->spec->mtu,$vtep->spec->mac,$vtep->spec->ip->ipAddress,$vtep->spec->ip->subnetMask);
					my $instkey = $vtep->spec->netStackInstanceKey;
					printf "\t%-6s%-6s%-20s%-16s%-16s%-16s%-20s\n", $vnic, $mtu, $mac, $ip, $mask,'', $instkey;
				}
	
			}
		}
	}

	#my $advops = ${Vim::get_view(mo_ref=>$_->configManager->advancedOption)}{supportedOption};
	if (defined $_->config->network) {
		my $netconf = $_->config->network;

		#### these are standard switches
		if (defined $netconf->vswitch) {
			foreach (@{$netconf->vswitch}) {
				next if ($_->name eq 'vSwitchiDRACvusb'); #skip the fake switch by dell
				print "\n[" . $_->name . "] (" . $_->mtu .")\n";

				# without uplink, the switch and portgroup will be useless
				next unless (defined $_->portgroup);
				foreach my $pgkey (@{$_->portgroup}) {
					foreach my $pg (@{$netconf->portgroup}) {
						if ($pg->key eq $pgkey) {
							my $team = $pg->computedPolicy->nicTeaming;
							my $pgname = $pg->spec->name;
							my $vlanid = $pg->spec->vlanId;
							my $teampolicy = (defined $team->policy)?$team->policy:'N/A';
							my $activeNic = (${$team->nicOrder}{'activeNic'})?
								color('green').join(":", @{${$team->nicOrder}{'activeNic'}}).color('reset'):'';
							my $standbyNic = (${$team->nicOrder}{'standbyNic'})?join(" ", @{${$team->nicOrder}{'standbyNic'}}):'';
							printf "\t%-45s%-8s%-20s%-30s%-30s\n", $pgname, $vlanid, $teampolicy, $activeNic, $standbyNic;
						}
					}
				}
			}
		}

		##### distributed switches have proxy/shadow on host.
		if (defined $netconf->proxySwitch) {
			foreach (@{$netconf->proxySwitch}) {
				my %uplinks; 
				foreach (@{$_->uplinkPort}) { $uplinks{$_->key} = $_->value; }

				my $switchname = $_->dvsName;
				#print "\n[$switchname: ".$_->dvsUuid. "] (" . $_->mtu . ")\n";
				print "\n[$switchname] (" . $_->mtu . ")\n";

				# since %uplinks  has only portkey=>uplink map, let's add uplink => dev into the same hash
				foreach my $pnic (sort {$a->uplinkPortKey<=>$b->uplinkPortKey} @{$_->spec->backing->pnicSpec}) {
					$uplinks{$uplinks{$pnic->uplinkPortKey}} = $pnic->pnicDevice;
			       	}

				# get the portgroups on this switch
				foreach my $net (@$hostnet) {
					next unless $net->type eq 'DistributedVirtualPortgroup';
					my $netview = $vim->get_view(mo_ref=>$net, properties=>['name','config']);
					if (${$vim->get_view(mo_ref => $netview->config->distributedVirtualSwitch)}{'name'} eq $switchname) {
						(my $pgname = $netview->name) =~ s/%2f/\//;
						my $config = $netview->config->defaultPortConfig;
						my $vlan = $config->vlan->vlanId;
						if (ref($vlan) eq 'ARRAY') {
							my $temp;
							foreach (@$vlan) { $temp = ($temp)? $temp.','.$_->start.'-'.$_->end:$_->start.'-'.$_->end;}
							$vlan = $temp;
						}
						my $policy = $config->uplinkTeamingPolicy->policy->value;

						# need the uplink map, but reverse it to search by vlaue. Only concat if it is not null: ($uplinks{$_}//'')
						my $activeNic = $config->uplinkTeamingPolicy->uplinkPortOrder->activeUplinkPort||'';
						$activeNic = ($activeNic)?join(' ',map {substr($_,-1) .':'.($uplinks{$_}//'')} @$activeNic):'';
						my $standbyNic = $config->uplinkTeamingPolicy->uplinkPortOrder->standbyUplinkPort||'';
						$standbyNic = ($standbyNic)?join(' ',map {substr($_,-1) .':'.($uplinks{$_}//'')} @$standbyNic):'';
						my $connection = color('green').$activeNic .color('reset'). ' '. $standbyNic;

						# shorten pgname
						$pgname =~ s/.{40}\K.*//s;
						printf "\t%-42s%-10s%-25s%-20s\n", $pgname, $vlan, $policy,$connection;
					}

				}
			}
		}

		#### nsx switches #####
		if (defined $netconf->opaqueSwitch) {
			foreach (@{$netconf->opaqueSwitch}) {
				#print "\n[" . $_->name . ": " . $_->key . "]\n";
				print "\n[" . $_->name . "]\n";
			}
		}
		if (defined $netconf->opaqueNetwork) {
			foreach (@{$netconf->opaqueNetwork}) {
				my $pniczone = join (':', @{$_->pnicZone});
				printf "\t%-50s%-40s%-40s\n", $_->opaqueNetworkName, $_->opaqueNetworkId, $pniczone;
			}
		}
		
	}

	my $advops = ${$vim->get_view(mo_ref=>$_->configManager->advancedOption, properties => ['setting'])}{setting};

=pod
	foreach (@$advops) { print $_->key . ": ".$_->value . "\n";}

	print $_->name ." ". $_->parent->type. ">\n"; 
	my $rp = Vim::find_entity_views(view_type => 'ResourcePool', filter=>{'name'=>'Resources'},begin_entity => $_->parent);
	foreach my $r (@$rp) {
		print $r->name."\n";
	}
=cut
}
=pod
=cut
################################
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
