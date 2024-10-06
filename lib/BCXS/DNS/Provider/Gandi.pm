package BCXS::DNS::Provider::Gandi;
use strict;

use JSON;
use LWP::UserAgent;
use Moose;
use Readonly;
use YAML;
use HTTP::Status qw(HTTP_NO_CONTENT);

has ua => (is => 'ro', isa => 'LWP::UserAgent', lazy => 1, default => sub { LWP::UserAgent->new });
has key => (is => 'rw', isa => 'Str'); # TODO lazy

Readonly my $API => 'https://api.gandi.net/v5';

sub BUILD {
	my ($self) = @_;

	my $fh = IO::File->new("$ENV{HOME}/.gandi-api-key", 'r');
	if (!$fh) {
		$fh = IO::File->new('/etc/gandi.key', 'r') or die $!;
	}

	chop(my $key = $fh->getline());

	$self->key($key);

	return;
}

sub loadZone {
	my ($self, $fqdn) = @_;

	my $zone = BCXS::DNS::Zone->new(fqdn => $fqdn, provider => $self);
	my $data = $self->__request('GET', "livedns/domains/$fqdn/records?per_page=1000");

	foreach my $rr (@$data) {
		$zone->addRecord($rr->{rrset_name}, $rr->{rrset_type}, $rr->{rrset_ttl}, $rr->{rrset_values});
	}

	return $zone;
}

sub createRecord {
	my ($self, $rr, $zone) = @_;

	$self->__promptRequest('POST', sprintf('livedns/domains/%s/records', $zone->fqdn), {
		rrset_name => $rr->name,
		rrset_type => $rr->type,
		rrset_ttl => $rr->ttl,
		rrset_values => $rr->values,
	});

	return;
}

sub updateRecord {
	my ($self, $rr, $zone) = @_;

	$self->__promptRequest('PUT', sprintf('livedns/domains/%s/records/%s/%s', $zone->fqdn, $rr->name, $rr->type), {
		rrset_name => $rr->name,
		rrset_type => $rr->type,
		rrset_ttl => $rr->ttl,
		rrset_values => $rr->values,
	});

	return;
}

sub deleteRecord {
	my ($self, $rr, $zone) = @_;

	$self->__promptRequest('DELETE', sprintf('livedns/domains/%s/records/%s/%s', $zone->fqdn, $rr->name, $rr->type));

	return;
}

sub __request {
	my ($self, $method, $path, $data) = @_;

	my $response = $self->__rawRequest($method, $path, $data);

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

sub __rawRequest {
	my ($self, $method, $path, $data) = @_;

	my $request = HTTP::Request->new($method, "$API/$path");
	$request->header('Authorization', sprintf('Apikey %s', $self->key));
	$request->content(encode_json($data)) if defined $data;

	return $self->ua->request($request);
}

sub __promptRequest {
	my ($self, $method, $path, $data) = @_;

	print "--------------\n";
	print "$method $path";
	if (defined $data) {
		my $encoded = encode_json($data);
		$encoded = substr($encoded, 0, 200).'...' if length($encoded) > 200;
		print " with data: $encoded";
	}
	print "\n";
	print "--- Execute? [y/N] ";

	my $answer = <STDIN>;
	if ($answer && $answer =~ /^y/i) {
		return request($method, $path, $data);
	}

	print "SKIPPED\n\n";
	sleep 1;
	return;
}
