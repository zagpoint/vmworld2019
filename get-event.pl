#!/usr/bin/perl -w
use strict;
use warnings;
use VMware::VIRuntime;
use Term::ANSIColor;
use Data::Dumper;
use DateTime;
##############################################
# Query vm configuration and stats           #
##############################################
# Written by: Zaigui Wang
# inspired by powercli: http://mattaltimar.com/?p=166
#
my $domain = 'vmware.com';
my %opts = (
	vm => { type => "=s", help => "VM name", required => 0},
	cluster => { type => "=s", help => "cluster name to look in", required => 0},
	host => { type => "=s", help => "host name to look in", required => 0},
	rp => { type => "=s", help => "resource pool to look in", required => 0},
	event => { type => "=s", help => "type of events. comma to delimit multiple. e.g.: com.vmware.vc.ha.VmRestartedByHAEvent", required => 0},
	message => { type => "=s", help => "message pattern to grep for", required => 0},
	key => { type => "=s", help => "event ID", required => 0},
	user => { type => "=s", help => "user", required => 0},
	severity => { type => "=s", help => "severity of event: info, warning, error,user", required => 0},
	duration => { type => "=s", help => "limit the query the last few weeks/days/hours/minutes. example, 1w/1d/1h/1m", required => 0},
	showevent => { type => "", help => "show me some event type examples", required => 0},
	eventchain => { type => "", help => "show all related events", required => 0},
);

# hash key with literal dot need to be quoted
my %eventype = (
	'esx.problem.net.redundancy.lost' => "lost uplink on a vSS",
	'esx.problem.net.vmknic.ip.duplicate' => 'Duplicate IP detected',
	'esx.problem.net.dvport.redundancy.degraded' => "uplink degraded",
	'esx.problem.net.dvport.redundancy.lost' =>  "lost vDS uplink",
	'esx.clear.net.redundancy.restored' => "restored uplink on a vSS",
	'esx.clear.net.dvport.redundancy.restored' => "vDS uplink stored",
	'com.vmware.vc.ha.VmRestartedByHAEvent' => "HA restarted a VM",
	'com.vmware.vc.HA.HostStateChangedEvent' => "HA event",
	VmMigratedEvent => "VM vmotioned manually",
	DrsVmMigratedEvent => "DRS migrated a VM",
	'com.vmware.vc.vm.DstVmMigratedEvent' => "VM Migrated in from a different VC",
	'com.vmware.vc.vm.DstVmMigrateFailedEvent' => "VM Migration into VC failed",
	'com.vmware.vc.vm.SrcVmMigrateFailedEvent' => "VM Migration out of VC failed",
	'com.vmware.vc.vm.SrcVmMigratedEvent' => "VM Migrated out to a different VC",
	EnteredMaintenanceModeEvent => 'Entering maintenance mode',
	ExitMaintenanceModeEvent => 'Exiting maintenance mode',
	HostConnectionLostEvent => 'a host is disconnected from VC',
	HostConnectedEvent => 'a host is now connected from vc',
	HostSyncFailedEvent => 'Error communicating to a remote host',
	VmCreatedEvent => "VM has been created",
	VmClonedEvent => "VM has been cloned",
	VmRemovedEvent => "VM has been removed from VC",
	VmReconfiguredEvent => "VM has been reconfigured",
	AlarmStatusChangedEvent => "Alarm has triggered",
	TaskEvent => "all admin tasks",
);

# validate options, and connect to the server
delete $ENV{'https_proxy'}; # this always seem to cause problem.
Opts::add_options(%opts);
Opts::parse();
if (Opts::option_is_set('showevent')) {
	printf "%-50s%-30s\n", $_, ' --' . $eventype{$_} for (sort keys %eventype);
	print "\nSee this for more events: https://www.virten.net/vmware/vcenter-events/\n";
	exit;
}
Opts::validate();

###
my $vmname = Opts::get_option('vm');
my $cluster = Opts::get_option('cluster');
my $hostname = Opts::get_option('host');
my $rp = Opts::get_option('rp');
my $server = Opts::get_option('server');
my $duration = Opts::get_option('duration');
my $event_string = Opts::get_option('event');
my @event = ($event_string)?split(',',$event_string):();
my $message = Opts::get_option('message');
my $key = Opts::get_option('key');
my $u = Opts::get_option('user');
my $severity = Opts::get_option('severity');
my $username = Opts::get_option('username');
my $password = Opts::get_option('password');
my $eventchain = Opts::option_is_set('eventchain');
#
# Establish a session...
my $vim = &create_session($server);
die "Failed to establish session...\n" unless $vim->{service_content};

# probably don't want an exact name in here, hence qr/$vmname/i, instead of qr/^$vmname$/i
# only one of them please. Specifying multiple won't help anybody.
my $mob;
if ($vmname || $cluster || $hostname) { 
	if ($vmname) {
		$mob = $vim->find_entity_view(view_type => 'VirtualMachine', filter=> {name => qr/^$vmname$/i}, 
			properties => ['name','config','resourceConfig','runtime','resourcePool']);
	}
	elsif ($cluster)  { $mob = $vim->find_entity_view(view_type => 'ComputeResource', filter => { 'name' => qr/^$cluster/i}); }
	elsif ($hostname) { $mob = $vim->find_entity_view(view_type => 'HostSystem', properties => ['name'], filter=>{'name'=>qr/^$hostname/});}
	else { $mob = $vim->find_entity_view(view_type => 'ResourcePool', properties => ['name'], filter=>{'name'=>qr/^$rp/});}
	die "Provided entity (vm/host/cluster/rp) not found" unless $mob;
}

# get eventmanager
print "Getting event manager...\n";
my $eventMgr = $vim->get_view(mo_ref => $vim->get_service_content()->eventManager);
my @entitySpec = ($mob)?(entity=>$mob):(); # if there is mob, no need to specify entityspec
my $recursion = EventFilterSpecRecursionOption->new("self");
my @entity = (@entitySpec)?(entity => EventFilterSpecByEntity->new(@entitySpec, recursion => $recursion)):();

# time duration object can be expressed like this in the subtract function: 
# days=>$d,hours=>$h,minutes=>$m, weeks=>$w, etc.
my @timeSpec = ();
my ($num,$unit,$units);
if ($duration) {
	die "ill-formated duration string!" unless $duration =~ /\d+(w|d|h|m)/;

	($num, $unit) = $duration =~ /(\d+)(.*)/;
	$units = (lc($unit) eq 'w')?'weeks':(lc($unit) eq 'd')?'days':(lc($unit) eq 'h')?'hours':'minutes';
	my $endTime = DateTime->now;
	my $beginTime = $endTime - DateTime::Duration->new($units=>$num);
	print "$beginTime ====> $endTime\n";
	@timeSpec = (time=>EventFilterSpecByTime->new(beginTime=>$beginTime, endTime=>$endTime));
}

###
my @eventSpec = (@event)? (eventTypeId => \@event):();
my @category = ($severity)? (category => [$severity]):();
my $filterSpec = EventFilterSpec->new(@entity, @timeSpec, @eventSpec, @category);

#
#print "Creating event collector...\n";
my $eventCollector = $eventMgr->CreateCollectorForEvents(filter => $filterSpec);
my $eventView = $vim->get_view(mo_ref => $eventCollector);
if (not defined $eventView->latestPage) {
	my $history='';
        $history= " for the last <$num> $units" if $duration;
	print "No events found$history. \n";
	exit;
}

my $page = $eventView->ReadNextEvents(maxCount => '200');
while (scalar @$page) {
	foreach (@$page) {
		if ($message) { next unless ($_->fullFormattedMessage =~ /$message/i) }
		if ($key) { next unless ($_->key =~ /$key/i) }

		my $etype = ref ($_);
		# Event type of 'EventEX' has its true type in 'eventTypeId'
		if (($etype eq  'EventEx') || ($etype eq 'ExtendedEvent')) { $etype = $etype . ":". $_->{'eventTypeId'}; }
		my $user = (defined $_->userName && $_->userName ne '')?$_->userName:""; $user =~ s/.*\\//;
		if ($u) { next unless ($user =~ /$u/i)}
		(my $time = $_->createdTime) =~ s/\.\d+Z//; #2017-05-20T06:23:49.890999Z

		# if specified eventtype, then we probably want to make sure that we get the chained event, if any:
		my ($ulen, $tlen, $olen, $object, $e_message); 
		if (@event && $_->chainId ne $_->key && $eventchain) {
			#print $_->vm->name. "\n";
			my $chainFilter = EventFilterSpec->new(eventChainId=>$_->chainId);
			my $chainCollector = $eventMgr->CreateCollectorForEvents(filter => $chainFilter);
			my $chainView = $vim->get_view(mo_ref => $chainCollector);
			my $chainEvent = $chainView->latestPage;
			foreach my $e (sort {$a->key cmp $b->key} @$chainEvent) {

				# for event type of "TaskEvengt", the entity/object is in info->entityName;
				$object = (defined $e->{'objectName'})?$e->{'objectName'}:(defined $e->{'info'}->{'entityName'})?$e->{'info'}->{'entityName'}:'';
				$e_message = $e->fullFormattedMessage;
				my $etype = ref ($e); 
				$tlen = length($etype) + 1;
				(my $etime = $e->createdTime) =~ s/\.\d+Z//;
				my $euser = (defined $e->userName && $e->userName ne '')?$e->userName:"";
				$ulen = length($euser) + 1;
				if ($object && $e_message !~ /$object/i) {
					$e_message = $object .": ". $e_message;
				}
				$e_message =~ s/Virtual machine/vm/g;
				printf "%-10s%-${tlen}s%-20s%-${ulen}s%-30s\n", $e->key, $etype, $etime, $euser,' ['.$e_message.']';
			}
		} else {
			$ulen = length($user) + 1;
			$tlen = length($etype) + 1;
			#$object = (defined $_->{'objectName'})?$_->{'objectName'}:'';
			$object = (defined $_->{'objectName'})?$_->{'objectName'}:(defined $_->{'info'}->{'entityName'})?$_->{'info'}->{'entityName'}:'';
			$e_message = $_->fullFormattedMessage;
			if ($object && $e_message !~ /$object/i) {
				$e_message = $object .": ". $e_message;
			}
			$e_message =~ s/Virtual machine/vm/g;
			printf "%-10s%-${tlen}s%-20s%-${ulen}s%-30s\n", $_->key, $etype, $time, $user, '['.$e_message.']';
		}
	}
	$page = $eventView->ReadNextEvents(maxCount => '200');
}

### Function definitions ####
sub create_session() {
        $|=1; # autoflush
	my $start = time;
        my $timeout = 10;
        my ($server) = @_;
	$server .= '.'. $domain unless ($server =~ /$domain/ || $server =~ /\d+\.\d+\.\d+\.\d+/);
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
                if (not $@) {print "\n".color('green') . "[$server]" . color('reset');}
                else { print "\n".color('red') . "[$server]: $@" . color('reset');}
        } else { print "\n".color('yellow') . "[$server]" . color('reset'); }

        # Return even if a login was unsuccessful. $vim->{'service_content'} is undef in such case.
	my $elapsed = sprintf("%.f", time - $start);
        print "(${elapsed}s) " ;
        return $vim;
}
