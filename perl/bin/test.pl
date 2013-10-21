#!/usr/bin/perl
use strict;
use warnings;
use Data::Dumper;
use Test::Simple tests => 48;
use JSON;

##### tests for PHPJobs::Client #####
use PHPJobs::Client;
my $base_url1 = 'http://remote.host/jobs.php';
my $base_url2 = 'http://changeme/phpjobs/jobs.php';
my $user_agent = 'PHPJobs test.pl';

my $client = PHPJobs::Client->new(
	'jobs_remote_url' => $base_url1,
	'debug' => 0,
	'extra_headers' => {'X-Foo' => 'Bar', 'User-Agent' => $user_agent},
	'unknown_option' => 42,
	'secure' => 1,
	'secret' => 'schmorflug'
);

# test PHPJobs::Client constructor
ok($client->{'_jobs_remote_url'} eq $base_url1, "base url set via constructor");
ok($client->remoteURL() eq $base_url1, "base url fetched via getter");
ok($client->{'_debug'} == 0, "debug option set to 0");
ok($client->{'_extra_headers'}->{'X-Foo'} eq 'Bar', "our custom header was set");
ok($client->{'_extra_headers'}->{'User-Agent'} eq $user_agent, "our custom user agent should override the default one");
ok(!defined($client->{'_unknown_option'}), "unknown options should be filtered out");

# test PHPJobs::Client::setRemoteURL
$client->setRemoteURL($base_url2);
ok($client->remoteURL() eq $base_url2, "setRemoteURL and remoteURL work as expected");

# test PHPJobs::Client::extraHeaders
my $initial_extra_headers = $client->extraHeaders();
ok(keys(%{$initial_extra_headers}) == 2, "extraHeaders works as expected (before setExtraHeader())");

# test PHPJobs::Client::setExtraHeader
$client->setExtraHeader('X-nanana' => 'Batman');
my $modified_extra_headers = $client->extraHeaders();
ok($modified_extra_headers->{'X-nanana'} eq 'Batman', "setExtraHeader works as expected");
ok(keys(%{$initial_extra_headers}) == 2, "extraHeaders works as expected (after setExtraHeader())");

# test PHPJobs::Client::setExtraHeaders
$client->setExtraHeaders($initial_extra_headers);
my $latest_extra_headers = $client->extraHeaders();
ok(keys(%{$latest_extra_headers}) == 2, "setExtraHeaders works as expected");

# test PHPJobs::Client::assembleDataForRequest
my $query_string = $client->assembleDataForRequest({'a' => 'b', 'c' => 'd', 'e' => 'phi khi psi'});
ok($query_string eq q[a=b&c=d&e=phi%20khi%20psi], "assembleDataForRequest works as expected");

# test PHPJobs::Client::assembleFilters
my $filter_parameters = PHPJobs::Client::assembleFilters(
	{'filter' => 'type', 'token' => 'test'},
	{'filter' => 'name', 'token' => 'foobar', 'op' => 'nm'},
	{'filter' => 'state', 'token' => 'finished'}
);
$query_string = $client->assembleDataForRequest($filter_parameters);
my $expected_query_string = q[filter=type&filter0=name&filter1=state&op0=nm&token=test&token0=foobar&token1=finished];
ok($query_string eq $expected_query_string, "assembleFilters works as expected");

# test PHPJobs::Client::composeURLForGETRequest
my $complete_url = $client->composeURLForGETRequest($filter_parameters);
ok($complete_url eq $base_url2 . '?' . $expected_query_string, "composeURLForGETRequest works as expected");

# test PHPJobs::Client::sendGETRequest
# $client->{'_debug'} = 1;
my $response = $client->sendGETRequest();
# $client->{'_debug'} = 0;
ok($response->{'_rc'} == 412, "sendGETRequest without any argument leads to HTTP 412");
ok($response->{'_headers'}->{'x-jobs-error'} =~ m#no action specified#, "sendGETRequest without any argument leads to expected error");

# test PHPJobs::Client::sendRangeGETRequest
$response = $client->sendRangeGETRequest(0, undef, {'action' => 'output', 'type' => 'system', 'name' => 'plcl-zMGRCvPfNH', 'output' => 'err'});
ok($response->{'_request'}->{'_headers'}->{'range'} eq q[bytes=0-], "sendRangeGETRequest works as expected");

# test PHPJobs::Client::sendPOSTRequest (create a first job running "echo coucou")
$response = $client->sendPOSTRequest({'action' => 'new', 'type' => 'system', 'name' => 'testpl', 'format' => 'json'}, {'command' => 'echo coucou'});
ok($response->{'_request'}->{'_method'} eq q[POST], "sendPOSTRequest sends a POST request");
ok($response->{'_request'}->{'_headers'}->{'content-type'} eq q[application/x-www-form-urlencoded], "sendPOSTRequest sends the expected Content-Type");
ok($response->{'_request'}->{'_content'} eq q[command=echo%20coucou], "sendPOSTRequest sends the expected content");

# test PHPJobs::Client::sendNewRequest (create a second job running "echo coucou; sleep 10")
$response = $client->sendNewRequest('system', 'testpl', {}, {'command' => 'echo coucou; sleep 10'});
ok($response->{'_rc'} == 200, "sendNewRequest triggers a 200 OK HTTP response");
my $response_hash = decode_json($response->{'_content'});
ok($response_hash->{'job-type'} eq q[system], "sendNewRequest creates the required type of job");
ok($response_hash->{'job-name'} =~ m#^testpl-.+$#, "sendNewRequest provides a new name for the required job");
my $current_job_name = $response_hash->{'job-name'};

# expected key for list and status tests
my $expected_key = 'system-' . $current_job_name . '.job.state';
sleep(1);

# test PHPJobs::Client::sendListRequest with two filters that should restrict output to the latest job we created
$response = $client->sendListRequest({'filter' => 'type', 'token' => 'system'}, {'filter' => 'name', 'token' => $current_job_name });
ok($response->{'_rc'} == 200, "sendListRequest triggers a 200 OK HTTP response");
$response_hash = decode_json($response->{'_content'});
ok(keys(%{$response_hash}) == 1, "sendListRequest returns only one item as expected");
my $first_key = (keys %{$response_hash})[0];
ok($first_key eq $expected_key, "sendListRequest returns the expected key");
ok(defined($response_hash->{$first_key}->{'worker-pid'}), "sendListRequest returns a worker-pid key");

# test PHPJobs::Client::sendStatusRequest with the same filters as sendListRequest
$response = $client->sendStatusRequest({'filter' => 'type', 'token' => 'system'}, {'filter' => 'name', 'token' => $current_job_name });
ok($response->{'_rc'} == 200, "sendStatusRequest triggers a 200 OK HTTP response");
$response_hash = decode_json($response->{'_content'});
ok(keys(%{$response_hash}) == 1, "sendStatusRequest returns only one item as expected");
$first_key = (keys %{$response_hash})[0];
ok($first_key eq $expected_key, "sendStatusRequest returns the expected key");
ok(defined($response_hash->{$first_key}->{'worker-status'}), "sendStatusRequest returns a worker-status key");

# test PHPJobs::Client::sendStatusRequest
$response = $client->sendKillRequest('system', $current_job_name, 'KILL');
ok($response->{'_rc'} == 200, "sendKillRequest triggers a 200 OK HTTP response");
$response_hash = decode_json($response->{'_content'});
$first_key = (keys %{$response_hash})[0];
ok($first_key eq q[kill_output], "sendStatusRequest returns the expected key");

# test PHPJobs::Client::sendOutputLengthRequest
$response = $client->sendOutputLengthRequest('system', $current_job_name, 'out');
ok($response->{'_rc'} == 200, "sendOutputLengthRequest triggers a 200 OK HTTP response");
ok($response->{'_headers'}->{'content-length'} == 7, "sendOutputLengthRequest returns the expected size");

# test PHPJobs::Client::sendOutputRequest
$response = $client->sendOutputRequest('system', $current_job_name, 'out');
ok($response->{'_rc'} == 200, "sendOutputRequest triggers a 200 OK HTTP response");
ok($response->{'_content'} eq "coucou\n", "sendOutputRequest returns the expected content");

# test PHPJobs::Client::sendOutputLengthRequest with a range
$response = $client->sendOutputRequest('system', $current_job_name, 'out', 3, 5);
ok($response->{'_rc'} == 206, "sendOutputRequest with a range triggers a 206 Partial Content HTTP response");
ok($response->{'_content'} eq q[cou], "sendOutputRequest with a range returns the expected content");
ok($response->{'_headers'}->{'content-length'} == 3, "sendOutputRequest with a range returns the expected Content-Length header");

##### tests for PHPJobs::Job #####
my $new_job = $client->newJob('system', undef, {}, {'command' => 'ls'});
ok($new_job->type() eq q[system], "Job class: freshly initialized job object has the expected type");
ok(!defined($new_job->name()), "Job class: freshly initialized job object has no name");

$new_job->run();
ok(defined($new_job->name()) && length($new_job->name()), "Job class: started job got a name");

$new_job->pollUntilStatus();
my $job_status = $new_job->lastStatus();
ok(defined($job_status->{'type'}) && $job_status->{'type'} eq 'system', "Job class: status returns the expected type");
ok(defined($job_status->{'name'}) && $job_status->{'name'} eq $new_job->name(), "Job class: status returns the expected name");
ok(defined($job_status->{'last_update_time'}), "Job class: status returns last update time.");

my $all_right = 1;
eval {
	my $long_job = $client->newJob('system', undef, {}, {'command' => 'sleep 60'})->run();
	$long_job->pollUntilStatus();
# 	$client->{'_debug'} = 1;
	$long_job->kill(9);
	1;
}
or do {
	$all_right = 0;
};
ok($all_right, "Job class: run, poll and kill succeeded");

my $expected_error = '';
eval {
	$client->newJob('system', undef, {}, {'command' => 'sleep 60'})->kill(9);
	1;
} or do {
	$expected_error = $@;
};
ok($expected_error =~ /^Cannot kill a name-less job object./, "Job class: got expected exception when trying to kill a non-started job");

# print Dumper($new_job);
$client->{'_debug'} = 0;
# print Dumper($new_job->status());
