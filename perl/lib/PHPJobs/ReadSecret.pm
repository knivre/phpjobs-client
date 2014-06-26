package PHPJobs::ReadSecret;
use Carp;
use Term::ReadPassword;

sub read_secret {
	my $target = shift;
	my $read_secret_from = shift;
	my $batch = shift;

	my $secret = '';
	if ($read_secret_from eq '-') {
		$secret = read_secret_from_keyboard($target, $batch);
	}
	else {
		$secret = read_secret_from_file($target, $read_secret_from);
		if (!length($secret)) {
			$secret = read_secret_from_keyboard($target, $batch);
		}
	}

	if (!length($secret)) {
		die 'Got empty secret, aborting';
	}
	return $secret;
}

sub read_secret_from_file {
	my $target = shift;
	my $read_secret_from = shift;

	my $secret;
	my $secret_fh;
	if (!open($secret_fh, '<', $read_secret_from)) {
		warn sprintf('Unable to read secret file %s: %s', $read_secret_from, $!);
	}
	else {
		$secret = <$secret_fh>;
		close($secret_fh);
		chomp($secret);
		if (!length($secret)) {
			warn sprintf('got empty secret for target %s', $target);
		}
	}
	return $secret;
}

sub read_secret_from_keyboard {
	my $target = shift;
	my $batch = shift;
	if ($batch) {
		die sprintf('Batch mode enforced: cannot read secret for %s from keyboard', $target);
	}
	return read_password(sprintf('Please enter secret for %s: ', $target));
}

1;
