package BCXS::DNS::Zone;
use strict;

use BCXS::DNS::Common;
use BCXS::DNS::RRSet;
use Moose;

has fqdn => (is => 'ro', isa => 'Str');

has provider => (is => 'ro'); # TODO type

has remote => (is => 'rw'); # TODO type

sub addIgnoredName {
	my ($self, $name, $type) = @_;

	if ($type) {
		$self->{__ignore}->{lc $name}->{types}->{lc $type} = 1;
	} else {
		$self->{__ignore}->{lc $name}->{all} = 1;
	}

	return;
}

sub addTTLMap {
	my ($self, $key, $value) = @_;

	$self->{__ttlMap}->{$key} = $value;

	return;
}

sub addRecord {
	my ($self, $name, $type, $ttl, $values) = @_;

	if ($type =~ /^_ALIAS(.*)/i) {
		$type = $1;
		my @types = ('A', 'AAAA');

		if ($type =~ m#^/(\w+)$#) {
			@types = ($1);
		}

		my $found;
		foreach my $type (@types) {
			my @resolved = grep { defined $_ } map { BCXS::DNS::Common::resolveName($type, $_, $self->fqdn) } @$values;
			foreach my $resolved (@resolved) {
				$self->addRecord($name, $type, $ttl, [ $resolved ]);
				$found = 1;
			}
		}
		die "Cannot find any records for alias $name in ".$self->fqdn unless $found;
		return;
	}

	if (!defined $ttl) {
		$ttl = 'SHORT';
	}

	if ($self->{__ttlMap} && defined $self->{__ttlMap}->{$ttl}) {
		$ttl = $self->{__ttlMap}->{$ttl};
	}

	if ($ttl !~ /^\d+$/) {
		die "Invalid ttl '$ttl' on $name/$type";
	}

	if (uc($type) eq 'TXT') {
		$values = [ map { /^".*"$/ ? $_ : "\"$_\"" } @$values ];
	}

	my $existing = $self->getRecord($name, $type);
	if ($existing) {
		push @{$existing->values}, @$values;
	} else {
		push @{$self->{__records}}, BCXS::DNS::RRSet->new(name => $name, type => $type, ttl => $ttl, values => $values, zone => $self);
	}

	return;
}

sub isIgnored {
	my ($self, $name, $type) = @_;

	return ($self->{__ignore}->{lc $name}->{all} || $self->{__ignore}->{lc $name}->{types}->{lc $type});
}

sub hasRecord {
	my ($self, $name, $type) = @_;

	return $self->getRecord($name, $type) ? 1 : 0;
}

sub addSPF {
	my ($self, $name, $entry) = @_;

	if (!defined $self->{__spf}->{$name}) {
		$self->{__spf}->{$name} = [];
	}

	if (defined $entry) {
		push @{$self->{__spf}->{$name}}, $entry;
	}

	return;
}

sub finalizeSPF {
	my ($self) = @_;

	while (my ($rr, $entries) = each %{$self->{__spf}}) {
		my $value = join(' ', 'v=spf1', @$entries, '-all');
		$self->addRecord($rr, 'TXT', 'LONG', [ $value ]);
	}

	return;
}

sub getRecords {
	my ($self) = @_;

	return @{$self->{__records}};
}

sub getRecord {
	my ($self, $name, $type) = @_;

	foreach my $rr (@{$self->{__records}}) {
		return $rr if lc($rr->name) eq lc($name) && lc($rr->type) eq lc($type);
	}

	return;
}

sub createRecord {
	my ($self, $rr) = @_;
	return $self->provider->createRecord($rr, $self);
}

sub updateRecord {
	my ($self, $rr, $other) = @_;
	return $self->provider->updateRecord($rr, $self, $other);
}

sub deleteRecord {
	my ($self, $rr) = @_;
	return $self->provider->deleteRecord($rr, $self);
}

1;
