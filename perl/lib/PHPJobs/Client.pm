package PHPJobs::Client;
use PHPJobs::Job;
use URI::Escape;
use LWP::UserAgent;
use Data::Dumper;
use Digest::SHA qw(sha256_hex);

# This class provides an abstraction layer to send HTTP requests to a PHPJobs
# instance and nothing more, i.e. it returns HTTP responses without checking
# them.

# Constructor
sub new {
	my $class = shift;
	my $self = {
		'_jobs_remote_url' => 'http://localhost/jobs.php',
		'_arg_separator' => '&',
		'_secure' => 0,
		'_secret' => '',
		'_debug' => 0,
		'_extra_headers' => {
			'User-Agent' => $class
		},
	};
	bless $self, $class;
	
	my %options = @_;
	if (%options) {
		# Keep known options as provided
		for my $option_name ('jobs_remote_url', 'arg_separator', 'secure', 'secret', 'debug') {
			if (defined($options{$option_name})) {
				$self->{'_' . $option_name} = $options{$option_name};
			}
		}
		
		# Merge provided extra headers with default ones
		$extra_headers = $options{'extra_headers'};
		map { $self->{'_extra_headers'}->{$_} = $extra_headers->{$_}; } (keys(%{$extra_headers}));
	}
	
	return $self;
}

## Simple getters/setters
sub remoteURL {
	return shift->{'_jobs_remote_url'};
}

sub setRemoteURL {
	$self = shift;
	$self->{'_jobs_remote_url'} = shift;
}

# return a *reference* (hashref) to a *copy* of all extra headers
sub extraHeaders {
	$self = shift;
	my %copy = %{$self->{'_extra_headers'}};
	return \%copy;
}

sub setExtraHeader {
	my ($self, $header, $value) = @_;
	$self->{'_extra_headers'}->{$header} = $value;
}

sub setExtraHeaders {
	$self = shift;
	$self->{'_extra_headers'} = shift;
}

## Technical helper methods

# Takes a hashref of parameter/value pairs and makes it a URL-Encoded string
sub assembleDataForRequest {
	my $self = shift;
	my $arguments = shift;
	
	my $data = '';
	if (defined($arguments)) {
		foreach my $key (sort(keys(%{$arguments}))) {
			$value = defined($arguments->{$key}) ? $arguments->{$key} : '';
			$data .= $self->{'_arg_separator'} if (length($data));
			$data .= uri_escape($key) . '=' . uri_escape($value);
		}
	}
	
	return $data;
}

# Take an array of hashrefs describing filters and return the resulting GET
# parameters
sub assembleFilters {
	my @filters = @_;
	
	my %get_parameters = ();
	for ($i = 0, $j = -1; $i < @filters; ++ $i) {
		$filter = $filters[$i];
		
		# Ensure the current filter provides at least a filter and a token
		next if (!defined($filter->{'filter'}) || !length($filter->{'filter'}));
		next if (!defined($filter->{'token'}) || !length($filter->{'token'}));
		
		$suffix = ($j > -1 ? $j : '');
		$get_parameters{'filter' . $suffix} = $filter->{'filter'};
		$get_parameters{'token' . $suffix} = $filter->{'token'};
		if (defined($filter->{'op'}) && length($filter->{'op'})) {
			$get_parameters{'op' . $suffix} = $filter->{'op'};
		}
		++ $j;
	}
	
	return \%get_parameters;
}

# Compose the destination GET URL from a hashref of parameter/value pairs
sub composeURLForGETRequest {
	($self, $arguments) = @_;
	
	$final_url = $self->remoteURL() . '?';
	$final_url .= $self->assembleDataForRequest($arguments);
	
	return $final_url;
}

sub generateSessionId() {
	my @chars = ('a'..'z', 'A'..'Z', '0'..'9');
	my $new_session_id;
	($new_session_id) = (`hostname` =~ m/^([^\.]+)/);
	chomp($new_session_id);
	$new_session_id .= '-';
	for ($i = 0; $i < 24; ++ $i) {
		$new_session_id .= $chars[rand(@chars)];
	}
	$self->{'_session_id'} = $new_session_id;
}

sub sessionId {
	my $self = shift;
	if (!defined($self->{'_session_id'})) {
		$self->generateSessionId();
	}
	return $self->{'_session_id'};
}

sub timestamp {
	if (!defined($self->{'_previous_timestamp'})) {
		$self->{'_previous_timestamp'} = 0;
	}
	my $timestamp = time();
	if ($timestamp != $self->{'_previous_timestamp'}) {
		$self->{'_previous_req_id'} = 1;
	}
	else {
		# we are still in the same second
		++ $self->{'_previous_req_id'};
	}
	$self->{'_previous_timestamp'} = $timestamp;
	my $complete_timestamp = sprintf('%s.%04d', $timestamp, $self->{'_previous_req_id'});
	return $complete_timestamp;
}

# Send a generic HTTP request, taking care to add our extra headers
sub sendRequest {
	my ($self, $request) = @_;
	
	my $ua = LWP::UserAgent->new();
	while (($header_name, $header_value) = each(%{$self->{'_extra_headers'}})) {
		$ua->default_header($header_name, $header_value);
	}
	
	if (defined($self->{'_secure'}) && $self->{'_secure'}) {
		# PHPJobs default security protocol consists in "signing" the HTTP
		# request with a secret that only the client and the server are
		# supposed to know. This signature includes some items to ensure the
		# request is reasonably not altered when it reaches the target server
		# while other items are mainly there to ensure the request cannot be
		# reused as is in case it would get eavesdropped.
		
		# we provide a security token made from...
		# - our intended target hostname, so the request cannot be reused on
		# another machine accepting the same secret, unless it also accepts this
		# hostname.
		# - GET data
		my ($target_hostname, $get_data) = ($request->{'_uri'} =~ m#^https?://([^/:]+)(?::[0-9]+)?/[^\?]+\?(.*)$#);
		# - POST data, which will be taken from $request->{'_content'}
		# - our session ID (which is chosen client-side)
		my $session_id = $self->sessionId();
		#  - a request id (composed by a standard Unix timestamp, followed by a dot
		# followed by the request number within that very second)...
		my $timestamp = $self->timestamp();
		# - and a secret shared with the server: $self->{'secret'}.
		# All of this is hashed using SHA256.
		my $hash_string = sprintf(
			'%s:%s@%s?%s&%s&%s',
			$session_id,
			$timestamp,
			$target_hostname,
			$get_data,
			$self->{'_secret'},
			$request->{'_content'}
		);
		my $hash = sha256_hex($hash_string);
		print $hash_string . "\n" if $self->{'_debug'};
		$ua->default_header('X-PHPJobs-Host', $target_hostname);
		$ua->default_header('X-PHPJobs-Session', $session_id);
		$ua->default_header('X-PHPJobs-Timestamp', $timestamp);
		$ua->default_header('X-PHPJobs-Security', $hash);
	}
	
	print '=> ' . Dumper($request) if ($self->{'_debug'});
	my $response = $ua->request($request);
	print '<= ' . Dumper($response) if ($self->{'_debug'});
	return $response;
}

# Send a generic GET HTTP request from a hashref of parameter/value pairs.
sub sendGETRequest {
	my ($self, $get_arguments) = @_;
	
	my $url = $self->composeURLForGETRequest($get_arguments);
	my $request = HTTP::Request->new('GET', $url);
	return $self->sendRequest($request);
}

# Send a "partial content" GET HTTP request from a hashref of parameter/value pairs.
sub sendRangeGETRequest {
	my ($self, $range_start, $range_end, $get_arguments) = @_;
	
	# Ensure the provided range is reasonable
	$range_start = '' if (!defined($range_start));
	$range_end = '' if (!defined($range_end));
	return 0 if (!length($range_start) && !length($range_end));
	
	my $url = $self->composeURLForGETRequest($get_arguments);
	my $request = HTTP::Request->new('GET', $url);
	$request->header('Range', 'bytes=' . $range_start . '-' . $range_end);
	return $self->sendRequest($request);
}

# Send a generic POST HTTP request from two hashrefs of parameter/value pairs
# (one for GET data, one for POST data).
sub sendPOSTRequest {
	my ($self, $get_arguments, $post_arguments) = @_;
	
	my $url = $self->composeURLForGETRequest($get_arguments);
	my $data = $self->assembleDataForRequest($post_arguments);
	
	my $request = HTTP::Request->new('POST', $url);
	$request->content_type('application/x-www-form-urlencoded');
	$request->content($data);
	return $self->sendRequest($request);
}

## Functional helper methods
# Send a new job request (ation=new)
sub sendNewRequest {
	my ($self, $job_type, $job_name, $get_arguments, $post_arguments) = @_;
	
	my %get_parameters = %{$get_arguments};
	# map { $get_parameters{$_} = $get_arguments->{$_}; } (keys(%{$get_arguments}));
	$get_parameters{'action'} = 'new';
	$get_parameters{'format'} = 'json';
	$get_parameters{'type'} = $job_type;
	$get_parameters{'name'} = $job_name if (defined($job_name) && length($job_name));
	
	if (defined($post_arguments)) {
		return $self->sendPOSTRequest(\%get_parameters, $post_arguments);
	}
	else {
		return $self->sendGETRequest(\%get_parameters);
	}
}

# Send a new list request (action=list), @filters being an array of hashref describing filters
sub sendListRequest {
	my ($self, @filters) = @_;
	
	my $get_parameters = PHPJobs::Client::assembleFilters(@filters);
	$get_parameters->{'action'} = 'list';
	$get_parameters->{'format'} = 'json';
	return $self->sendGETRequest($get_parameters);
}

sub sendStatusRequest {
	my ($self, @filters) = @_;
	
	my $get_parameters = PHPJobs::Client::assembleFilters(@filters);
	$get_parameters->{'action'} = 'status';
	$get_parameters->{'format'} = 'json';
	return $self->sendGETRequest($get_parameters);
}

sub sendKillRequest {
	my ($self, $job_type, $job_name, $signal) = @_;
	
	my $get_parameters = {
		'action' => 'kill',
		'type' => $job_type,
		'name' => $job_name,
		'format' => 'json',
	};
	if (defined($signal) && length($signal)) {
		$get_parameters{'signal'} = $signal;
	}
	return $self->sendGETRequest($get_parameters);
}

sub sendOutputRequest {
	my ($self, $job_type, $job_name, $output, $range_start, $range_end) = @_;
	
	my $get_parameters = {
		'action' => 'output',
		'type' => $job_type,
		'name' => $job_name
	};
	
	if (defined($output) && length($output)) {
		$get_parameters->{'output'} = $output;
	}
	
	if (defined($range_start) || defined($range_end)) {
		return $self->sendRangeGETRequest($range_start, $range_end, $get_parameters);
	}
	else {
		return $self->sendGETRequest($get_parameters);
	}
}

sub sendOutputLengthRequest {
	my ($self, $job_type, $job_name, $output) = @_;
	
	my $head_parameters = {
		'action' => 'output',
		'type' => $job_type,
		'name' => $job_name
	};
	if (defined($output) && length($output)) {
		$head_parameters{'output'} = $output;
	}
	my $url = $self->composeURLForGETRequest($head_parameters);
	my $request = HTTP::Request->new('HEAD', $url);
	return $self->sendRequest($request);
}

# implement PHPJobs's "new" action
sub newJob {
	my ($self, $job_type, $job_name, $get_arguments, $post_arguments) = @_;
	return PHPJobs::Job->new($self, $job_type, $job_name, $get_arguments, $post_arguments);
}

1;
