#!/usr/bin/perl

use HTTP::Status qw(HTTP_NO_CONTENT);
use JSON;
use LWP::UserAgent;
use Readonly;

Readonly my $API => 'https://api.gandi.net/v5';

my $KEY;

sub init {
	$ua = LWP::UserAgent->new;

	my $fh = IO::File->new("$ENV{HOME}/.gandi-api-key", 'r');
	if (!$fh) {
		$fh = IO::File->new('/etc/gandi.key', 'r') or die $!;
	}

	chop($KEY = $fh->getline());

	$| = 1;

	return;
}

sub request {
	my ($method, $path, $data) = @_;

	my $response = rawRequest($method, $path, $data);

	if (!$response->is_success) {
		die "$method $path: ".$response->as_string();
	}

	if ($response->code == HTTP_NO_CONTENT) {
		print "$method $path returned no data\n";
		return undef;
	}

	my $decoded = decode_json($response->content);

	return $decoded;
}

sub rawRequest {
	my ($method, $path, $data) = @_;

	my $request = HTTP::Request->new($method, "$API/$path");
	$request->header('Authorization', "Apikey $KEY");
	$request->content(encode_json($data)) if defined $data;

	return $ua->request($request);
}

1;
