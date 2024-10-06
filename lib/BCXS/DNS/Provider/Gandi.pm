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

	my $data = $self->__request('GET', "livedns/domains/$fqdn/records?per_page=1000");
	my %data;

	foreach my $rr (sort { ($a->{rrset_name} cmp $b->{rrset_name}) || ($a->{rrset_type} cmp $b->{rrset_type}) } @$data) {
		$data{$rr->{rrset_name}.'/'.$rr->{rrset_type}} = $rr;

		foreach my $val (sort @{$rr->{rrset_values}}) {
			my $name = $rr->{rrset_name};
			my $rr_fqdn;
			if ($name eq '@') {
				$rr_fqdn = "$fqdn.";
			} else {
				$rr_fqdn = "$name.$fqdn.";
			}
		}
	}

	return \%data;
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
