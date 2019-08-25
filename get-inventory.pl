#!/usr/bin/perl -w
# perl sdk script to retrieve mobs from VC. You'll need the vcli (or perl sdk) package from vmware installed to get this working
# by Zaigui Wang
#
use strict;
use warnings;
use Sort::Naturally;
use VMware::VIRuntime;
use Data::Dumper;
use Term::ANSIColor;
use feature qw(say);
my %opts = ( dc=> {type => "=s", help => "Optional: data center", required => 0},
	cluster => { type=>"=s", help => "Optional: cluster Name", required => 0},
	showvm => { type=>"", help => "Optional: with vm detail", required=>0},
	detail => { type=>"", help => "Optional: show more detail, for example host IP/moid, etc", required=>0},
	clusteronly => { type=>"", help => "Optional: shows only clustered hosts", required=>0},
	nohost => { type=>"", help => "Optional: hides hosts info", required=>0},
	getlicense => { type=>"", help => "Optional: include license info", required=>0},
	vcinfo => { type=>"", help => "Optional: get VC information only", required=>0},
	clusterinfo => { type=>"", help => "Optional: get cluster information only", required=>0},
);
#
# validate options, and connect to the server
#delete $ENV{'https_proxy'};
Opts::add_options(%opts);
Opts::parse();
my $domain = 'vmware.com';
my $dcName = Opts::get_option('dc');
my $server = Opts::get_option('server'); 
unless ($server =~ /$domain/ || $server =~ /\d+\.\d+\.\d+\.\d+/) {$server .= '.'.$domain;}
my $clusterName = Opts::get_option("cluster");
my $showvm = Opts::option_is_set("showvm");
my $detail = Opts::option_is_set("detail");
my $clusteronly = Opts::option_is_set("clusteronly");
my $nohost = Opts::option_is_set("nohost");
my $getlicense = Opts::option_is_set("getlicense");
my $vcinfo = Opts::option_is_set("vcinfo");
my $clusterinfo = Opts::option_is_set("clusterinfo");
Opts::validate();
my $username = Opts::get_option('username');
my $password = Opts::get_option('password');

# Establish a session...
my $vim = &create_session($server);
die "Failed to establish session...\n" unless (defined $vim->{'service_content'});

my $si = $vim->get_service_instance();
my $content = $vim->get_service_content();

my $ID;
my $setting = $vim->get_view(mo_ref => $content->setting);
foreach (@{$setting->setting}) { if ($_->key eq 'instance.id') {$ID = $_->value;}}

# grabbing some extension information, such as SRM and NSX
my $extension = $vim->get_view(mo_ref => $content->extensionManager, properties => ['extensionList']);
my ($nsx, $srm, $vum, $vcops,$bde,$vr,$vCC,$appd,$vxrail) = ('') x 9;
foreach (@{$extension->extensionList}) {
	my $key = $_->key;
	my $server = (defined $_->{'client'})?@{$_->client}[0]->url:(defined $_->{'server'})?@{$_->server}[0]->url:'';

	# to deal with the new VR plugin issue. Why is server IP in "server" not in "client" any more...
	if ($server !~ /https/) {
		$server = @{$_->server}[0]->url if $server;
		$server =~ s#(.*?)\|(.*)#$2#g;
	}

	$server =~ s#https?://(.*?)[:|/](.*)#$1#g if $server;
	$server =~ s/(.*?)(\d+\.\d+\.\d+\.\d+)(.*?)/$2/g if $server;
	$server =~ s#.$domain## if $server;
	print $server."\n" if ($key =~ /nsxt/);

	my $ver = $_->version;

	# convert IP to name
	use Socket;
	my $ip = inet_aton("$server");
	my $name = gethostbyaddr($ip, AF_INET) if $ip;
	$name =~ s#.$domain##i if $name;

	###
	if ($key =~ 'vcDr') {
		if ($name) { $srm = ($srm)?" $srm $name ($ver)":" | SRM: $name ($ver)"; } 
		else { $srm = ($srm)?" $srm $server ($ver)":" | SRM: $server ($ver)"; }
	} 
	if ($key =~ 'vcHms') {
		$vr = ($name)?" | VR: $name ($ver)":" | VR: $server ($ver)";
	}
	if ($key =~ /vShieldManager|nsxt/) {
		$nsx = ($name)?" | NSX: $name ($ver)":" | NSX: $server ($ver)";
	}
	if ($key =~ /nsxt/) {$nsx = ($name)?" | nsxt: $name ($ver)":" | nsxt: $server ($ver)"; }
	if ($key =~ 'vcIntegrity') { $vum = ($name)?" | VUM: $name ($ver)":" | VUM: $server ($ver)"; }
	if ($key =~ 'vcops') {
	       	$vcops = ($name)?" | vROps: $name ($ver)":" | vROps: $server ($ver)";
	}
	if ($key =~ 'appd') {$appd = ($name)?" | appD: $name ($ver)":" | appD: $server ($ver)";}
	if ($key =~ 'vxrail') {
		$vxrail = ($name)?" | vxrail: $name ($ver)":" | vxrail: $server ($ver)";
	}
}

# looking at VC settings to figure out database and SSO
my $optionManager = $vim->get_view(mo_ref=>$content->setting);
my ($sso,$ssoadmin, $dbdsn,$dbtype) = ('NA', 'NA', 'NA','');
if (eval {$optionManager->QueryOptions(name=>'config.vpxd.sso.sts.uri')}) { $sso = @{$optionManager->QueryOptions(name=>'config.vpxd.sso.sts.uri')}[0]->value;}
if (eval {$optionManager->QueryOptions(name=>'config.vpxd.odbc.dbtype')}) { $dbtype = @{$optionManager->QueryOptions(name=>'config.vpxd.odbc.dbtype')}[0]->value;}
if (eval {$optionManager->QueryOptions(name=>'config.vpxd.odbc.dsn')}) { $dbdsn = @{$optionManager->QueryOptions(name=>'config.vpxd.odbc.dsn')}[0]->value;}
if (eval {$optionManager->QueryOptions(name=>'config.vpxd.sso.default.admin')}) { $ssoadmin = @{$optionManager->QueryOptions(name=>'config.vpxd.sso.default.admin')}[0]->value;}
$sso =~ s/.*?\/\/(.*?)\/.*/$1/g;
$sso =~ s/\.$domain//g;
if ($server =~ m/$sso/) { 
	$sso = '';
}

# get some version information here: ESXi, VC, vSAN by web-scrapping from the following KBs. Just need a couple of columns by headers
my %map = &getVersionMap();
#
my $vcType = ($content->about->{'osType'} eq 'linux-x64')?'VCSA':'Windows';
my $vcVersion = $content->about->{'version'};
my $vcBuild = $content->about->{'build'};
my $vcUUID = $content->about->{'instanceUuid'};
my $DSN = ($dbtype eq 'embedded')?" DB: embedded":"| DB: $dbdsn ($dbtype)";
$ssoadmin = ' (' . $ssoadmin . ')' if $ssoadmin;
$sso = "PSC: $sso$ssoadmin |" if $sso;
my $release = ($map{'vc'}{$vcBuild})?$map{'vc'}{$vcBuild}:'';
print color("bold magenta") . "VC: $server $vcUUID (#$ID)".color('reset')." | $vcType $vcBuild-$release | $sso$DSN$nsx$srm$vr$vcops$vum$bde$vCC$appd$vxrail\n";
$vcinfo && exit;
if ($getlicense) {
	my $lm = $content->licenseManager;
	my $lmv = $vim->get_view(mo_ref => $lm, properties => ['licenses']);
	my ($d, $m, $y) = (localtime())[3,4,5];
	my $now = sprintf "%d-%02d-%02d", $y+1900, $m+1, $d+30;
	printf "%-50s%-35s%7s%-10s\n", '[Product]', '[License Key]', '[Used]', ' [Expiration Date]';
	foreach my $lic (@{$lmv->licenses}) {
		(my $name = $lic->name) =~ s/.{48}\K.*//s;
		my $exp = "never";
		next if ($name =~ /Product Evaluation/);
		foreach (@{$lic->properties}) {
			if (ref $_->value eq 'LicenseManagerLicenseInfo') {
				foreach (@{$_->value->properties}) {
					if ($_->key eq 'expirationDate') {
						($exp = $_->value) =~ s/.*\KT.*//g;
						$exp = color('red') . $exp . color('reset') if ($now gt $exp);
						last;
					}
				}
			}
		}
		printf "%-50s%-35s%7d%-10s\n", $name, $lic->licenseKey, ($lic->used)?$lic->used:0, ' '.$exp;
	}
	exit;
}

#####
my ($dc, $clusters, $haState, $connState,$DNSname,$inMaint, $toolsOK, $hostVersion, $hostBuild, $vsanVersion, $hw, $numCPU, $typeCPU,$genCPU, $memory,$SN, $st, $et);
my $mb = "";

if ($dcName) { $dc= $vim->find_entity_view(view_type=>"Datacenter",properties=>["name"],filter=>{'name' => $dcName });
	die "DC $dcName not found!" unless ($dc);
}

my @scope=();
if ($dc) {@scope = (begin_entity => $dc)};
my @filter = ($clusterName)?(filter=>{'name'=>qr/^$clusterName/i}):();

$st = scalar localtime();
$clusters = $vim->find_entity_views(view_type => 'ClusterComputeResource', properties => ['summary','name','host','configurationEx','datastore'], @filter, @scope);
exit 1 unless (@$clusters);

# When a particular cluster is not requested, also need to capture any non-clustered hosts 
if ((not $clusterName) and (not $clusteronly)) {
	my ($hosts, @solos, $href); 
	$hosts = $vim->find_entity_views(view_type => 'HostSystem', properties => ['name','parent'], @scope); 
	if (@$hosts) { foreach (@$hosts) { push(@solos, $_->{'mo_ref'}) if ($_->parent->type eq 'ComputeResource');} }

	# faking a cluster by blessing with cluster type: ClusterComputeResource
	$href = bless {name=>'All Standalone Hosts ******', host=>\@solos}, "ClusterComputeResource";
	if (@solos) { push(@$clusters, $href); }
} 

# sort the cluster by name
my @sorted_clusters = sort {ncmp ($a->name, $b->name)} @$clusters;
my $numVM = 0;
foreach (@sorted_clusters)  {  
	my $EVC = (defined $_->summary && defined $_->summary->currentEVCModeKey)?':'.color('red').$_->summary->currentEVCModeKey.color('reset'):'';
	my $DRS ='';
       	$DRS = $_->{configurationEx}->{drsConfig}->{defaultVmBehavior}->{val} if (defined $_->{configurationEx}->{drsConfig});
	$DRS = ':DRS-' . $DRS if $DRS;
	if (defined ($_->host)) {
		my $nhost = scalar @{$_->host};
		my $cluster_moid = ($detail && defined $_->{mo_ref})?"::". $_->{'mo_ref'}->value:'';
		print color('bold green') . $server. $cluster_moid .":".$_->name. $EVC . color('reset') . color("cyan"). $DRS. color("reset");

		# vSAN specific stuff
		my $isVsan = 0;
		if (defined $_->{'configurationEx'}->{'vsanConfigInfo'}) {
			if ($_->{'configurationEx'}->{'vsanConfigInfo'}->{'enabled'}) {
				my ($ds, $free, $cap, $usepct, $usebar);

				$ds = $vim->get_views(mo_ref_array => $_->datastore);
				foreach my $item (@$ds) { 
					# we only care about vsan space availability and vm count.
					if ($item->summary->type eq 'vsan') {
						# Regardless of whether this is real vsandatastore or the "logical" datastore, VM count still holds
						$numVM += (defined $item->vm)?@{$item->vm}:0;

						#Capacity is a different story. Let's discount the logical datastore here by excluding ds with "aliasOf" set
						if (! defined $item->{'info'}->{'aliasOf'}) {
							$cap += sprintf("%.f",$item->summary->capacity/1024**4);
							$free += sprintf("%.f", $item->summary->freeSpace/1024**4);
							$usepct = sprintf("%.1f", ($cap-$free)/$cap)*10 if $cap;
							$usebar = sprintf "\x{25aa}" x $usepct . "\x{25ab}" x (10-$usepct);
						}
					}
				}
				print ' '.color('on_green')."vSAN-ENABLED".color('reset')." [UUID: ".$_->{'configurationEx'}->{'vsanConfigInfo'}->defaultConfig->uuid.",Storage: ${cap}TB $usebar, VMs: $numVM]";
				$isVsan = 1;
			}
		}
		($nhost < 2)? print " ($nhost host)\n":print " ($nhost hosts)\n";
		$clusterinfo && next;

		# get some creative use of get_view!
		my @sorted = sort{ncmp (${$vim->get_view(mo_ref=>$a, properties=>['name'])}{name}, ${$vim->get_view(mo_ref=>$b, properties=>['name'])}{name})} @{$_->host};

		# I need to pre-walk the cluster and figure out the hostname length:
		my $hlen = 0;
		foreach (@sorted) { 
			my $name = ${$vim->get_view(mo_ref => $_, properties => ['name'])}{'name'};
			$name =~ s/.$domain//;
			$hlen = length $name if (length $name > $hlen);
		}
		
		foreach my $host_ref (@sorted) {  
			my $host_view = $vim->get_view(mo_ref => $host_ref, properties => ['vm','name','config.product', 'runtime.connectionState',
					'runtime.dasHostState','runtime.inMaintenanceMode','parent','summary','config.network.vnic','recentTask']);
			my $ipaddr = ' ';
			if ($detail) {
				# assuming vmk0 is the management IP. may not aways be true.
				foreach (@{$host_view->{'config.network.vnic'}}) { $ipaddr = $_->spec->ip->ipAddress if ($_->device eq 'vmk0');}
			}

			my $uptime = (defined $host_view->{summary}->{quickStats}->uptime)?$host_view->{summary}->{quickStats}->uptime:0;
			if ($uptime > 86400) { $uptime = sprintf("%.f", $uptime/24/3600).'d';} #anything more than a day, use day
			elsif ($uptime > 21600) { $uptime = sprintf("%.f", $uptime/3600).'h';} #anything more than 5 hours, use hour
			else { $uptime = $uptime = sprintf("%.f", $uptime/60).'m';}		#anything else, use minutes
			$uptime = "[\x{2191} $uptime]";
			
			my $cpucap = $host_view->{summary}->{hardware}->numCpuCores * $host_view->{summary}->{hardware}->cpuMhz; #in Mhz
			my $memcap = $host_view->{summary}->{hardware}->memorySize/1024**2; #in MB 
			my $cpuusage = $host_view->{summary}->{quickStats}->overallCpuUsage; #in mHZ
			my $memusage = $host_view->{summary}->{quickStats}->overallMemoryUsage; #in MB
			my ($cpupct, $mempct) = (0,0);
			$cpupct = sprintf("%.1f", $cpuusage/$cpucap)*10 if ($cpuusage);
			$mempct = sprintf("%.1f", $memusage/$memcap)*10 if ($memusage); 
			my $cpubar = sprintf "\x{25aa}" x $cpupct . "\x{25ab}" x (10-$cpupct);
			my $membar = sprintf "\x{25aa}" x $mempct . "\x{25ab}" x (10-$mempct);
			my $width = ($detail)?11:0;
			my $host_moid = sprintf("%-${width}s", ($detail)?$host_view->{'mo_ref'}->value:'');
			(my $hostname = $host_view->name) =~ s/.$domain//;
			$hostname = sprintf("%-${hlen}s", $hostname);
			$connState = ($host_view->{'runtime.connectionState'}->val eq 'connected')?'':color('red')." [".$host_view->{'runtime.connectionState'}->val."]".color('reset');
			$haState = (defined $host_view->{'runtime.dasHostState'}->{'state'})?"[".$host_view->{'runtime.dasHostState'}->{'state'}."]":'';
			$haState = "[slave ]" if ($haState eq '[connectedToMaster]');
			$inMaint = ($host_view->{'runtime.inMaintenanceMode'} eq 'true')?color("red").' (Maintenance)'.color("reset"):'';
			$hostBuild = (defined($host_view->{'config.product'}))? $host_view->{'config.product'}->build:color('red').'***Build ?***'.color('reset');
			if ($hostBuild =~ /\d+/) {
				$vsanVersion = $map{'vsan'}{$hostBuild};
				$vsanVersion = '-'.$vsanVersion if $vsanVersion; # not found in KB
				$hostVersion = $map{'esx'}{$hostBuild};
				if (! $hostVersion) { $hostVersion = (defined($host_view->{'config.product'}))?$host_view->{'config.product'}->version:'NIKB';}
				if ($isVsan && $vsanVersion) {
					(my $vsanVN = $vsanVersion) =~ s/^\S+\s*//;
					(my $hostVN = $hostVersion) =~ s/^\S+\s*//;
					$hostVersion = $hostVersion.$vsanVersion if ($vsanVN ne $hostVN)
				}
			}
			$hostVersion = "" unless $hostVersion;

			# Get hardware model info
			$hw = $host_view->{summary}->{hardware}->model;
			(my $vendor = $host_view->{summary}->{hardware}->vendor) =~ s/(\S+).*/$1/g;
			#$hw = "$vendor $hw"; 

			# getting S/N
			if (defined $host_view->{summary}->{hardware}->otherIdentifyingInfo) {
				foreach (@{$host_view->{summary}->{hardware}->otherIdentifyingInfo}) {
					if ($_->identifierType->{'key'} eq 'ServiceTag') {
						$SN=$_->identifierValue;
						last;
					}
				}
				$SN = color('red').'***Unknown'.color('reset') unless $SN;
			} else { $SN=color('red').'***Unknown'.color('reset'); }

			$numCPU = $host_view->{summary}->{hardware}->numCpuPkgs."x".($host_view->{summary}->{hardware}->numCpuCores)/($host_view->{summary}->{hardware}->numCpuPkgs);
			($typeCPU = $host_view->{summary}->{hardware}->cpuModel) =~ s/(Intel|AMD).*?\s(.*)/$2/;
			$typeCPU =~ s/(\(R\)|\(tm\))//gi;
			$typeCPU =~ s/(Processor|CPU)//gi;
			$typeCPU =~ s/[\h\v]+/ /g; #squeez out the spaces
			$typeCPU =~ s/\s\@\s/\@/;
			$memory = sprintf("%.f", $memcap/1024) ."G";
			
			# note this is limited by the vsphere version, not by the hardware - hardware capability might be higher.
			if (defined $host_view->{summary}->{maxEVCModeKey}) {
				($genCPU = $host_view->{summary}->{maxEVCModeKey}) =~ s/.*-(.*)/$1/; 
			} else { $genCPU = 'UNKNOWN';}

			my $symbol = "\x{26A1}"; # unicode cloud ☁  2601 or power 26A1
			print "   $host_moid $ipaddr $hostname [$hostBuild-$hostVersion] [$hw] [$SN] [$genCPU $numCPU $typeCPU $cpubar] [$memory $membar] $haState $uptime$inMaint$connState" unless $nohost;

			if (defined ($host_view->vm)) {
				my $nvm = scalar @{$host_view->vm};
				($nvm < 2)? print " ($nvm vm)\n":print " ($nvm vms)\n" unless $nohost;

				if ($showvm) {
				foreach my $vm_ref (@{$host_view->vm}) {  
					my $ft = '';
					my $vm = $vim->get_view(mo_ref => $vm_ref, properties => ['name', 'config','summary.storage.committed', 'runtime.powerState', 'guest']);  
					my $vwidth = ($detail)?10:0;
					my $vm_moid = sprintf("%-${vwidth}s", ($detail)?$vm->{'mo_ref'}->value:'');

                                        # this is to skip any "inaccessible" vms.
                                        if ($vm->guest->guestState eq 'unknown') {
                                                print "\t\t".$vm->name. "$vm_moid in unknown state\n";
                                                next;
                                        }

					if (defined $vm->config->{'ftInfo'}) { $ft = ($vm->config->ftInfo->role eq 1)? 
							color("magenta").' <FT:Primary>'.color('reset'):color('magenta').' <FT:Secondary>'.color('reset'); }
					$toolsOK=(($vm->{'runtime.powerState'}->val eq "poweredOn") and ($vm->guest->toolsRunningStatus ne 'guestToolsRunning'))?
							color('red'). " [".$vm->guest->toolsRunningStatus."]".color('reset'):''; 
					$DNSname=(defined($vm->guest->hostName))?$vm->guest->hostName:'';

					# get the IP and MAC addresses
					my $IP = '';
					my $MAC = '';
					if (($vm->guest->guestState eq 'running') and (defined $vm->guest->net)) {
						foreach(@{$vm->guest->net}) { 
							if (defined $_->ipAddress) {
								my $ip = (${$_->ipAddress}[0] =~ /\./)?${$_->ipAddress}[0]:${$_->ipAddress}[1]; # this is to get the ipv4, not the ipv6, one.
								$ip =~ s/169.254..*/0.0.0.0/g if $ip;
								$IP = ($IP)?"$IP|$ip":"$ip" if $ip;

								my $mac = $_->macAddress;
								$MAC = ($MAC)?"$MAC|$mac":"$mac" if $mac;
							}
						}
					}
					else { #get the mac address from hardware info: $vm->config->hardware->device 
						foreach (@{$vm->config->hardware->device}) {
							if (eval {$_->macAddress}) { my $mac = $_->macAddress; $MAC = ($MAC)?"$MAC|$mac":"$mac" if $mac; }
						}
					}

					$IP = " [$IP]" if $IP;
					$MAC = " [$MAC]" if $MAC;
					$DNSname =~ s/.$domain// unless ($DNSname eq '');
					my $dns=(($DNSname ne '') && (lc $DNSname ne lc $vm->name))?"($DNSname)":'';

					# get the OS/product
					my $product;
					if (defined $vm->config->vAppConfig) { foreach (@{$vm->config->vAppConfig->product}) { $product = $_->name unless (! $_->{'name'});}}
					if (!$product) { if ($vm->guest->guestState eq 'running') { $product = $vm->guest->guestFullName;}}
					$product = $vm->config->guestFullName. '?' unless $product;
					$product =~ s/ or later/\+/g;
					$product = ' ['. $product . ']';

					my $storage = sprintf("%.f", $vm->{'summary.storage.committed'}/1024**3);
					$storage = color('bold red') . $storage . color('reset') if ($storage > 1024);
					my $nCPU = $vm->config->hardware->numCPU;
					my $nCORE = $vm->config->hardware->numCoresPerSocket;
					$nCORE = 1 unless $nCORE;
					my $nSOCK = $nCPU/$nCORE;
					my $memOS = sprintf('%.f', $vm->config->hardware->memoryMB/1024);
					$memOS = color('bold red') . $memOS . color('reset') if ($memOS > 32);

					# Medium circles. or use 25ef and 2b24 for larger circles
					my $LED=($vm->{'runtime.powerState'}->val eq "poweredOn")?"\x{26ab}":"\x{26aa}";
					if (defined($vm->config->managedBy)) { $mb = " <".$vm->config->managedBy->type.">"; } else {$mb = '';}
					my $vm_name = sprintf("%-35s",$vm->name . " $dns");

					print "\t\t$LED $vm_name $vm_moid [" . $nSOCK.'x'.$nCORE.'/'.$memOS.'G/'.$storage.'G]'. "$IP$MAC$product$mb$ft$toolsOK\n";
				}}
			} else { print "\n";}
		}  
	}
}  
$et = scalar localtime();
print "\nStarted: $st.\nCompleted: $et\n" if (@sorted_clusters);

### Function definitions ####
sub create_session() {
        $|=1; # autoflush
        my $start = time;
        my $timeout = 10;
        my ($server) = @_;
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
###
sub getVersionMap() {
        use WWW::Mechanize;
        use HTML::TableExtract;
        use JSON::XS qw(encode_json decode_json);
        use File::Slurp qw(read_file write_file);
        my $dump = "/tmp/dump.json";
        my $age = 5;
        my (%map, $json);

        if ( ! -f $dump || -M $dump > $age) {
                my %urls = (
			vc => "https://kb.vmware.com/articleview?docid=2143838",
                        esx => "https://kb.vmware.com/articleview?docid=2143832",
                        vsan => 'https://kb.vmware.com/articleview?docid=2150753',
                );
                foreach my $product (keys %urls) {
                        print "Scraping $product verison info from KB ".$urls{$product} . "\n";
			#my @headers = ($product eq 'vsan')?(headers => ['BuildNumber','vSAN version']):(headers => ['Build Number','Version']);
			my @headers = ($product eq 'vsan')?(headers => ['BuildNumber','vSAN version']):(headers =>['(Build Number|MOB)','Version']);
                        my $html = WWW::Mechanize->new( autocheck => 1 );
                        do {eval {$html->get($urls{$product})};} until $html->res->is_success;

                        my $table = HTML::TableExtract->new(@headers);
			$table->parse($html->content);

			foreach my $ts ($table->tables) {
				foreach my $row ($ts->rows) {
					next unless (@$row[0] =~ /^[0-9]/); # non-breaking space interference \x{a0}
					 (my $b = @$row[0]) =~ s/[\n\r]|^\s+|\s+$|\t//g;
					 (my $v = @$row[1]) =~ s/[\n\r]|^\s+|\s+$|\t//g;

					 # we don't want a key like this: "7070488replaces 4602587"
					 # But do we need to note the replacement? Need to save $2 here and append to $v value
					 $b =~ s/(\d+)\s?\D+\s+(\d+)/$1/;
					 $v =~ s/vCenter Server |VirtualCenter //g;
					 $v =~ s/.*Appliance //g;
					 $v =~ s/ ?\(.*?\) ?//g;
					 $v =~ s/Express Patch /EP/g;
					 $v =~ s/EP /EP/g;
					 $v =~ s/Patch /P/g;
					 $v =~ s/Update /U/g;

					 # Multiple release nubmers for same product. Let's record as multiple entries
					 if ($b =~ m#/#) { $map{$product}{$_} = $v for (split('/', $b)); } 
					 else { $map{$product}{$b} = $v;}
				 }
                        }
                }

                # write the file to dump
                my $json = encode_json \%map;
                write_file($dump, {binmode => ':raw'}, $json);
        } else {
                print "Reading version info from $dump...\n";
                $json = read_file($dump, {binmode=>':raw'}); %map = %{decode_json $json};
        }
        return %map;
}
