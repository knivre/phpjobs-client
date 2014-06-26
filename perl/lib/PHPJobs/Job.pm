package PHPJobs::Job;
use PHPJobs::Client;
use LWP::UserAgent;
use Scalar::Util;
use Data::Dumper;
use URI::Escape;
use JSON;
use Carp;


sub new {
	my $class = shift;
	my $self = {};
	bless $self, $class;
	
	$self->{'_client'} = shift;
	$self->setType(shift);
	$self->{'_initial_name'} = shift;
	
	$self->{'_get_parameters'} = shift;
	$self->{'_post_parameters'} = shift;
	return $self;
}

## getters/setters
sub type {
	return shift->{'_type'};
}

sub setType {
	my ($self, $type) = @_;
	PHPJobs::Job::checkJobIdentifier('job type', $type, sub { return $_[0] =~  m#^[a-zA-Z0-9_]+$#; });
	$self->{'_type'} = $type;
}

sub name {
	return shift->{'_name'};
}

sub setName {
	my ($self, $name) = @_;
	PHPJobs::Job::checkJobIdentifier('job name', $name, sub { return $_[0] =~  m#^[a-zA-Z0-9_-]+$#; });
	$self->{'_name'} = $name;
}

sub checkJobIdentifier {
	my $string_semantic = shift;
	my $string_value = shift;
	my $check_sub = shift;
	
	if (!defined($string_value)) {
		croak($string_semantic . ' should not be undefined');
	}
	
	if (!length($string_value)) {
		croak($string_semantic . ' should not be empty');
	}
	
	if (!$check_sub->($string_value)) {
		croak(
			sprintf(
				'%s "%s" contains forbidden characters',
				$string_semantic,
				$string_value
			)
		);
	}
	
	return 1;
}

sub GETParameters {
	return $self->{'_get_parameters'};
}

sub setGETParameters {
	my ($self, $get_parameters) = @_;
	$self->{'_get_parameters'} = $get_parameters;
}

sub POSTParameters {
	return $self->{'_post_parameters'};
}

sub setPOSTParameters {
	my ($self, $post_parameters) = @_;
	$self->{'_post_parameters'} = $post_parameters;
}

sub run {
	my $self = shift;
	
	$http_response = $self->{'_client'}->sendNewRequest(
		$self->{'_type'},
		$self->{'_initial_name'},
		$self->{'_get_parameters'},
		$self->{'_post_parameters'}
	);
	
	# we also expect a JSON-formatted HTTP response
	my $response_hash = PHPJobs::Job::checkHTTPResponse($http_response);
	
	# we expect a non-empty job-name to be returned
	if (!defined($response_hash->{'job-name'})) {
		die('Job creation returned HTTP 200 but no job name was provided.');
	}
	if (!length($response_hash->{'job-name'})) {
		die('Job creation returned HTTP 200 but an empty job name was provided.');
	}
	$self->{'_name'} = $response_hash->{'job-name'};
	
	return $self;
}

sub status {
	my $self = shift;
	
	if (!defined($self->{'_name'})) {
		croak('Cannot get status of name-less job object.');
	}
	$http_response = $self->{'_client'}->sendStatusRequest(
		{
			'filter' => 'type',
			'token' => $self->{'_type'}
		},
		{
			'filter' => 'name',
			'token' => $self->{'_name'}
		}
	);
	
	# we also expect a JSON-formatted HTTP response
	my $response_hash = PHPJobs::Job::checkHTTPResponse($http_response);
	$self->{'_last_status'} = PHPJobs::Job::checkSingleKey($response_hash);
	return $self->{'_last_status'};
}

sub lastStatus {
	my $self = shift;
	if (defined($self->{'_last_status'})) {
		return $self->{'_last_status'};
	}
	return $self->status();
}

# run() returns the acknowledge supplied by the front web service but this does
# not mean the job actually started; especially, the worker process needs some
# time to fire up and create a status entry, hence the existence of this method.
sub pollUntilStatus {
	my ($self, $interval, $max_tries) = @_;
	$interval = 500 if (!defined($interval));
	$max_tries = 10 if (!defined($max_tries));
	
	my $status;
	for (my $i = 0; $i < $max_tries; ++ $i) {
		# print $i . q[... ];
		eval {
			$status = $self->status();
			1;
		}
		or do {
			# nothing, we just ignore any exception
		};
		# get out of the subroutine if status was successfully retrieved.
		return 1 if (defined($status));
		# sleep unless it was the last iteration
		PHPJobs::Job::sleep($interval) if ($i != $max_tries - 1);
	}
	return defined($status);
}

sub checkHTTPResponse {
	my $http_response = shift;
	
	# We expect a standard HTTP 200 response
	PHPJobs::Job::checkHTTPStatus($http_response);
	
	# we also expect a JSON-formatted HTTP response
	my $response_hash;
	eval {
		# decode_json may die, typically with the following message:
		# "malformed JSON string, neither array, object, number, string or atom"
		$response_hash = decode_json($http_response->{'_content'});
		
		# PHPJobs server may return an empty result, which will be translated to
		# an empty array in JSON ('[]') but also in Perl. Handle this case.
		$response_hash = {} if (ref($response_hash) eq 'ARRAY');
		1;
	}
	or do {
		$response_hash = {};
	};
	
	return $response_hash;
}

sub checkHTTPStatus {
	my $http_response = shift;
	my @acceptable_status = @_;
	
	@acceptable_status = (200) if (!@acceptable_status);
	my $status_ok = 0;
	map { $status_ok = 1 if ($http_response->{'_rc'} == $_)  } @acceptable_status;
	if (!$status_ok) {
		if (defined($http_response->{'_headers'}->{'x-jobs-error'})) {
			$error_message = $http_response->{'_headers'}->{'x-jobs-error'};
		}
		else {
			$error_message = 'Failed with HTTP status ' . $http_response->{'_rc'};
		}
		die($error_message);
	}
}

sub checkSingleKey {
	my $hash = shift;
	my $expected_key = shift;
	if (keys(%{$hash}) != 1) {
		die(sprintf('Expected single key in JSON response, found %d', scalar(keys(%{$hash}))));
	}
	$first_key = (keys %{$hash})[0];
	# optionally check the first key against the provided one
	if (defined($expected_key)) {
		if ($first_key ne $expected_key) {
			die(sprintf('Expected key "%s", got "%s"', $expected_key, $first_key));
		}
	}
	return $hash->{$first_key};
}

sub kill {
	my $self = shift;
	my $signal = shift;
	
	if (!defined($self->{'_name'})) {
		die('Cannot kill a name-less job object.');
	}
	
	my $http_response = $self->{'_client'}->sendKillRequest($self->{'_type'}, $self->{'_name'}, $signal);
	my $response_hash = PHPJobs::Job::checkHTTPResponse($http_response);
	my $response = PHPJobs::Job::checkSingleKey($response_hash, 'kill_output');
	return $response;
}

sub output {
	my $self = shift;
	
	if (!defined($self->{'_name'})) {
		die('Cannot get output for a name-less job object.');
	}
	
# 	$self->{'_client'}->{'_debug'} = 1;
	my $http_response = $self->{'_client'}->sendOutputRequest($self->{'_type'}, $self->{'_name'}, @_);
# 	$self->{'_client'}->{'_debug'} = 0;
	PHPJobs::Job::checkHTTPStatus($http_response, 200, 206);
	return $http_response->{'_content'};
}

sub outputLength {
	my $self = shift;
	my $output = shift;
	
	if (!defined($self->{'_name'})) {
		die('Cannot get output length for a name-less job object.');
	}
	
	my $http_response = $self->{'_client'}->sendOutputLengthRequest($self->{'_type'}, $self->{'_name'}, $output);
	PHPJobs::Job::checkHTTPStatus($http_response, 200);
	return $http_response->{'_headers'}->{'content-length'};
}

sub sleep {
	select(undef, undef, undef, $_[0] / 1000);
}

1;
