package BCXS::DNS::Zone;
use strict;

use Moose;
use BCXS::DNS::RRSet;

has fqdn => (is => 'ro', isa => 'Str');

has provider => (is => 'ro'); # TODO type

# TODO make configurable
my %TTL_MAP = (
	SHORT => 300,
	MEDIUM => 3600,
	LONG => 86400,
);

sub addIgnoredName {
	my ($self, $name, $type) = @_;

	if ($type) {
		push @{$self->{__ignore}}, "$name/$type";
	} else {
		push @{$self->{__ignore}}, $name;
	}

	return;
}

sub addRecord {
	my ($self, $name, $type, $ttl, $values) = @_;

	$ttl = $TTL_MAP{$ttl} if exists $TTL_MAP{$ttl};

	push @{$self->{__records}}, BCXS::DNS::RRSet->new(name => $name, type => $type, ttl => $ttl, values => $values);
	return;
}

sub addSPF {
	my ($self, $name, $entry) = @_;

	push @{$self->{__spf}->{$name}}, $entry;

	return;
}

sub finalizeSPF {
	my ($self) = @_;

	return unless $self->{__spf};

	while (my ($rr, $entries) = each %{$self->{__spf}}) {
		$self->addRecord($rr, 'TXT', 'LONG', join(' ', 'v=spf1', @$entries, '-all'));
	}

	return;
}

1;
