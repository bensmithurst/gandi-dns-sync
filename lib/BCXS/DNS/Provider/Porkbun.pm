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

		my $content = $record->{content};
		if ($record->{type} eq 'MX' || $record->{type} eq 'SRV') {
			$content = sprintf('%d %s', $record->{prio}, $record->{content});
		}

		$zone->addRecord($name, $record->{type}, $record->{ttl}, [ $content ]);
	}

	return $zone;
}

sub createRecord {
	my ($self, $rr, $zone) = @_;

	foreach my $value (@{$rr->values}) {
		$self->__request(sprintf('create/%s', $zone->fqdn), $self->__makeDataForRequest($rr, $value));
	}

	return;
}

sub updateRecord {
	my ($self, $rr, $zone) = @_;

	if (scalar(@{$rr->values}) == 1) {
		my $path = sprintf('editByNameType/%s/%s', $zone->fqdn, $rr->type);
		$path .= sprintf('/%s', $rr->name) if $rr->name ne '@';

		$self->__request($path, $self->__makeDataForRequest($rr, $rr->values->[0]));
	} else {
		$self->deleteRecord($rr, $zone);
		$self->createRecord($rr, $zone);
	}

	return;
}

sub deleteRecord {
	my ($self, $rr, $zone) = @_;

	my $path = sprintf('deleteByNameType/%s/%s', $zone->fqdn, $rr->type);
	$path .= sprintf('/%s', $rr->name) if $rr->name ne '@';

	$self->__request($path, {});

	return;
}

sub __makeDataForRequest {
	my ($self, $rr, $value) = @_;

	my $data = {
		name => $rr->name,
		type => $rr->type,
		ttl => $rr->ttl,
		content => $value,
	};

	if ((uc($rr->type) eq 'MX' || uc($rr->type) eq 'SRV') && $value =~ /^(\d+)\s+(.*)$/) {
		$data->{content} = $2;
		$data->{prio} = $1;
	}

	return $data;
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

	my %copy = %$data;
	$copy{apikey} = 'REDACTED';
	$copy{secretapikey} = 'REDACTED';

	printf("%s: %s\n", $path, encode_json(\%copy));

	return $self->ua->request($request);
}

1;
