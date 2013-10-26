package PHPJobs::System::Client;
use PHPJobs::Client;
our @ISA = ('PHPJobs::Client');

sub new {
	my $class = shift;
	my $self = PHPJobs::Client->new(@_);
	$self->{'env_vars'} = ();
	bless $self, $class;
	return $self;
}

sub setEnvironmentVariable() {
	$self = shift;
	$env_var_name = shift;
	$env_var_value = shift;
	$self->{'env_vars'}->{$env_var_name} = $env_var_value;
}

sub unsetEnvironmentVariable() {
	$self = shift;
	$env_var_name = shift;
	$self->{'env_vars'}->{$env_var_name} = undef;
}

sub executeCommand {
	my ($self, $command_string, $cwd, $user_options) = @_;
	
	# Default options...
	%options = (
		'fetch_err' => 1,
		'fetch_out' => 1,
		'output_bytes_received' => 0,
		'errput_bytes_received' => 0,
	);
	# ... get overridden with provided options.
	if (defined($user_options)) {
		map { $options{$_} = $user_options->{$_}; } (keys(%{$user_options}));
	}
	
	# Prepare arguments:
	# 1 - command line and current working directory
	$post_arguments = {'command' => $command_string, 'cwd' => $cwd};
	
	# 2 - environment variables
	$i = 0;
	foreach my $env_var_name (keys(%{ $self->{'env_vars'} })) {
		$env_string = $env_var_name;
		# Environment variables associated to the undef value are to be unset;
		# this is achieved by sending only "NAME" instead of the usual
		# "NAME=VALUE" syntax.
		if (defined($self->{'env_vars'}->{$env_var_name})) {
			$env_string .= '=' . $self->{'env_vars'}->{$env_var_name};
		}
		$post_arguments->{'env' . $i} = $env_string;
		++ $i;
	}
	
	# start given command
	my $command = $self->newJob('system', 'plcl', {}, $post_arguments);
	$command->run();
	# do not do anything until we have a first status
	$command->pollUntilStatus();
	
	my $sleep_time = 800;
	my $command_status;
	my $iter = 0;
	while (1) {
		# check job status
		$command_status = $command->lastStatus()->{'worker-status'};
		
		$self->handleOutput($command, 'err', \%options) if ($options{'fetch_err'});
		$self->handleOutput($command, 'out', \%options) if ($options{'fetch_out'});
		
		# get out of the loop if the remote job ended
		last if ($command_status eq 'not-running');
		
		# sleep between iterations
		PHPJobs::Job::sleep($sleep_time);
		$command->status();
	}
	
	# Handle return code
	my $rc = $command->lastStatus()->{'return_code'};
	return $rc;
}

sub handleOutput {
	($self, $command, $output_type, $options) = @_;
	return if ($output_type ne 'out' && $output_type ne 'err');
	
	eval {
		my $bytes_received = $output_type . 'put_bytes_received';
		my $callback = 'callback_' . $output_type;
		
		# whatever the results, fetch as much output as possible
		my $content = $command->output($output_type, $options->{$bytes_received});
		$options->{$bytes_received} += length($content);
		if (defined($options{$callback})) {
			$options{$callback}($content);
		}
		else {
			my $fh = $output_type eq 'err' ? STDERR : STDOUT;
			print $fh $content;
		}
		1;
	}
	or do {
		# ignore HTTP 416 errors
		die($@) if ($@ !~ m/^Failed with HTTP status 416/);
		# Technically, we could check whether the remote size changed by
		# issuing a HEAD request and checking the Content-Length header in the
		# resulting response; however, that would imply an extra round-trip to
		# the remote server so we stick to a simpler approach: polling using
		# Range requests starting from our latest retrieved byte and ignoring
		# HTTP 416 Requested Range Not Satisfiable.
	}
}

1;
