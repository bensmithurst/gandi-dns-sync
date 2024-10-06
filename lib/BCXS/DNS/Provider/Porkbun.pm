package BCXS::DNS::Provider::Porkbun;
use strict;

use HTTP::Status qw(HTTP_NO_CONTENT);
use JSON;
use LWP::UserAgent;
use Moose;
use Readonly;
use YAML qw(LoadFile);

has ua => (is => 'ro', isa => 'LWP::UserAgent', lazy => 1, default => sub { LWP::UserAgent->new });
has ['apiKey', 'secretKey'] => (is => 'rw', isa => 'Str');

Readonly my $API => 'https://api.porkbun.com/api/json/v3/dns/';

sub BUILD {
	my ($self) = @_;

	my $data = LoadFile("$ENV{HOME}/.porkbun.yaml");

	$self->apiKey($data->{api_key});
	$self->secretKey($data->{secret_key});

	return;
}

sub loadZone {
	my ($self, $fqdn) = @_;

	my $data = $self->__request(sprintf('retrieve/%s', $fqdn));

	my $zone = BCXS::DNS::Zone->new(fqdn => $fqdn, provider => $self);

	foreach my $record (@{$data->{records}}) {
		my $name = $record->{name};
		if ($name eq $fqdn) {
			$name = '@';
		} elsif ($name =~ /(.*)\.\Q$fqdn\E$/) {
			$name = $1;
		} else {
			die "Bad name $name for zone $fqdn";
		}

		print Data::Dumper::Dumper($record);
		print "name is '$name'\n";

		$zone->addRecord($name, $record->{type}, $record->{ttl}, [ $record->{content} ]);
	}

	return $zone;
}

sub createRecord {
	my ($self, $rr, $zone) = @_;

	foreach my $value (@{$rr->values}) {
		my $data = {
			name => $rr->name,
			type => $rr->type,
			ttl => $rr->ttl,
			content => $value,
		};

		if (uc($rr->type) eq 'MX' && $value =~ /^(\d+)\s+(\S+)$/) {
			$data->{content} = $2;
			$data->{priority} = $1;
		}

		$self->__request(sprintf('create/%s', $zone->fqdn), $data);
	}

	return;
}

sub __request {
	my ($self, $path, $data) = @_;

	my $response = $self->__rawRequest($path, $data);

	if (!$response->is_success) {
		print "$path: ".$response->as_string()."\n";
		return undef;
	}

	if ($response->code == HTTP_NO_CONTENT) {
		print "$path returned no data\n";
		return undef;
	}

	my $decoded = decode_json($response->content);

	if ($decoded->{status} ne 'SUCCESS') {
		print $response->content;
		print "$path: failed\n";
		return undef;
	}

	return $decoded;
}

sub __rawRequest {
	my ($self, $path, $data) = @_;

	my $request = HTTP::Request->new('POST', "$API/$path");
	$data->{apikey} = $self->apiKey;
	$data->{secretapikey} = $self->secretKey;
	$request->content(encode_json($data));

	print "$path: ".$request->content."\n";

	return $self->ua->request($request);
}

1;
