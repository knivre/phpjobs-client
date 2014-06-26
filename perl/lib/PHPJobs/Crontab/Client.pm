package PHPJobs::Crontab::Client;
use PHPJobs::Client;
our @ISA = ('PHPJobs::Client');

sub new {
	my $class = shift;
	my $self = PHPJobs::Client->new(@_);
	$self->{'env_vars'} = ();
	bless $self, $class;
	return $self;
}

sub execSynchronously() {
	my $self = shift;

	# Run a new "crontab" job named "plcl" using the provided GET and POST
	# parameters.
	my $crontab_job = $self->newJob('crontab', 'plcl', @_);
	$crontab_job->run();

	# Calls to crontab are not expected to take a tremendous amount of time, so
	# the asynchronous behaviour of PHPJobs is not really useful here.
	# Do not do anything until we have a first status.
	if ($crontab_job->pollUntilStatus()) {
		# Once we have a status, poll until the job has finished.
		while ($crontab_job->lastStatus()->{'worker-status'} ne 'not-running') {
			# sleep between iterations
			PHPJobs::Job::sleep(100);
			$crontab_job->status();
		}
		print STDERR $crontab_job->output('err');
		return $crontab_job->output('out');
	}
}

sub get {
	return shift->execSynchronously({'command' => 'get'});
}

sub set {
	my ($self, $crontab) = @_;
	return $self->execSynchronously({'command' => 'set'}, {'crontab' => $crontab});
}

sub setFromFileHandle {
	my ($self, $fh) = @_;
	# slurp the whole file into a single scalar
	return $self->set(join('', <$fh>));
}

sub setFromFile {
	my ($self, $filepath) = @_;
	open(my $fh, '<', $filepath) or die(sprintf('Unable to open %s: %s', $filepath, $!));
	my $result = $self->setFromFileHandle($fh);
	close($fh);
	return $result;
}

1;
