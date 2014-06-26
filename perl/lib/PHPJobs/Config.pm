package PHPJobs::Config;
use File::Basename;
use PHPJobs::Client;

# Constructor
sub new {
	my $class = shift;
	my $self = {
		'_conf_file_path' => $class->environmentConfigFilePath(),
	};
	bless $self, $class;
	$self->setConfigFilePath(shift);
	return $self;
}

# return the default filepath this class looks for, typically ~/.phpjobs/config
sub defaultConfigFilePath {
	return sprintf('%s/.phpjobs/config', $ENV{'HOME'});
}

# return the filepath to be used according to the environment
sub environmentConfigFilePath {
	my $conf_file_path = PHPJobs::Config->defaultConfigFilePath();
	
	my $pjsh_env_var = 'PHPJOBS_CONFIG';
	if (defined($ENV{$pjsh_env_var})) {
		if (! -f $ENV{$pjsh_env_var}) {
			warn sprintf('%s mentions non-existent or non-regular file %s, ignoring', $pjsh_env_var, $ENV{$pjsh_env_var});
		}
		else {
			if (! -r $ENV{$pjsh_env_var}) {
				warn sprintf('%s mentions non-readable file %s, ignoring', $pjsh_env_var, $ENV{$pjsh_env_var});
			}
			else {
				$conf_file_path = $ENV{$pjsh_env_var};
			}
		}
	}
	
	return $conf_file_path;
}

sub configFilePath {
	return shift->{'_conf_file_path'};
}

sub setConfigFilePath {
	my $self = shift;
	my $file_path = shift;
	return if (!defined($file_path));
	if (! -f $file_path) {
		die sprintf('%s does not exist or is not a regular file', $file_path);
	}
	if (! -r $file_path) {
		die sprintf('%s is not readable', $file_path);
	}
	$self->{'_conf_file_path'} = $file_path;
}

sub getConfigurationDirectivesForTarget {
	my $self = shift;
	my $target = shift;
	
	my @target_conf = ();
	
	# do not attempt to provide configuration directives for target URLs
	return \@target_conf if ($target =~ m#^https?://#);
	
	
	# Open the configuration file
	my $conf_file_path = $self->configFilePath();
	my $conf_fh;
	if (!open($conf_fh, '<', $conf_file_path)) {
		die sprintf('Unable to open configuration file %s: %s', $conf_file_path, $!);
	}
	
	# Parse the configuration file
	my $host_section = 0;
	while (<$conf_fh>) {
		my @matches = ();
		# Handle "HostMatch" sections
		if (@matches = (m#^\s*HostMatch\s*(\S+)\s*$#i)) {
			# We entered a HostMatch Section
			if ($target =~ m{$matches[0]}) {
				# The target matches the pattern
				$host_section = 1;
				next;
			}
			else {
				$host_section = 0;
			}
		}
		
		# Handle "Host" sections
		if (@matches = (m#^\s*Host\s+(\S+)\s*$#i)) {
			# We entered a "Host" section
			if ($target eq $matches[0]) {
				# we entered a host section that match our target
				$host_section = 1;
				next;
			}
			else {
				# we entered another host section
				$host_section = 0;
			}
		}
		
		# Harvest known directives if needed
		if ($host_section) {
			@matches = (m#^\s*(AccessURL|NSM|NSMSecretFile|WipeHeaders)\s+(\S+)\s*$#i);
			if (!@matches) {
				@matches = (m#^\s*(Header)\s+(\S+)\s+(\S+)\s*$#i);
			}
			if (!@matches) {
				@matches = (m#^\s*(Alias)\s+(\S+)\s+(.+)\s*#i);
			}
			push(@target_conf, \@matches) if (@matches);
		}
	}
	close($conf_fh);
	return \@target_conf;
}

sub getConfigurationForTarget {
	my $self = shift;
	my $target = shift;
	
	my %target_conf = ();
	
	# do not attempt to fetch configuration directives for target URLs
	if ($target =~ m#^https?://#) {
		$target_conf{'target_url'} = $target;
		return \%target_conf;
	}
	
	my $conf_file_path = $self->configFilePath();
	my $target_directives = $self->getConfigurationDirectivesForTarget($target);
	if (!@{$target_directives}) {
		die sprintf('No directives were found in %s for target "%s"', $conf_file_path, $target);
	}
	
	# hardcoded default options
	my $target_url = '';
	my $secure = 0;
	my $read_secret_from = '-';
	my %extra_headers = ();
	my %aliases = ();
	
	# Take configuration directives into account
	foreach my $conf_line (@{$target_directives}) {
		my $directive = @{$conf_line}[0];
		if ($directive eq 'AccessURL') {
			$target_url = @{$conf_line}[1];
			# "AccessURL" directives may contain a %h pattern which gets
			# replaced with the given target
			$target_url =~ s#%h#$target#gi;
		}
		elsif ($directive =~ m#^NSM$#i) {
			$secure = 0 if (@{$conf_line}[1] =~ m#(?:no|off|disabled|0)#i);
			$secure = 1 if (@{$conf_line}[1] =~ m#(?:yes|on|enabled|1)#i);
		}
		elsif ($directive =~ m#^NSMSecretFile$#i) {
			$read_secret_from = @{$conf_line}[1];
			# Paths are relative to the configuration file's directory
			if ($read_secret_from !~ m#^/#) {
				$read_secret_from = dirname($conf_file_path) . '/' . $read_secret_from;
			}
		}
		elsif ($directive =~ m#^WipeHeaders$#i) {
			my $wipe_pattern = @{$conf_line}[1];
			delete $extra_headers{$_} for grep(m/$wipe_pattern/i, keys(%extra_headers));
		}
		elsif ($directive =~ m#^Header$#i) {
			# Silently discard value-less headers
			if (@{$conf_line} == 3) {
				my ($header, $value) = (@{$conf_line}[1], @{$conf_line}[2]);
				$extra_headers{$header} = $value;
			}
		}
		elsif ($directive =~ m#^Alias$#i) {
			$aliases{ @{$conf_line}[1] } = @{$conf_line}[2];
		}
	}
	
	$target_conf{'target_url'} = $target_url;
	$target_conf{'secure'} = $secure;
	$target_conf{'read_secret_from'} = $read_secret_from;
	$target_conf{'extra_headers'} = \%extra_headers;
	$target_conf{'aliases'} = \%aliases;
	return \%target_conf;
}

1;
