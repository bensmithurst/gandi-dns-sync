#!/usr/bin/perl

Readonly my $API => 'https://api.gandi.net/v5';

my $KEY;

sub init {
	$ua = LWP::UserAgent->new;

	my $fh = IO::File->new("$ENV{HOME}/.gandi-api-key", 'r') or die $!;

	chop($KEY = $fh->getline());

	$| = 1;

	return;
}

sub rawRequest {
	my ($method, $path, $data) = @_;

	my $request = HTTP::Request->new($method, "$API/$path");
	$request->header('Authorization', "Apikey $KEY");
	$request->content(encode_json($data)) if defined $data;

	return $ua->request($request);
}

1;
