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
		$self->{__ignore}->{lc $name}->{types}->{lc $type} = 1;
	} else {
		$self->{__ignore}->{lc $name}->{all} = 1;
	}

	return;
}

sub addRecord {
	my ($self, $name, $type, $ttl, $values) = @_;

	if ($type =~ /^ALIAS(.*)/i) {
		$type = $1;
		my @types = ('A', 'AAAA');

		if ($type =~ m#^/(\w+)$#) {
			@types = ($1);
		}

		my $found;
		foreach my $type (@types) {
			# FIXME main:: call
			my @resolved = grep { defined $_ } map { main::__resolveName($type, $_, $self->fqdn) } @$values;
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

	$ttl = $TTL_MAP{$ttl} if exists $TTL_MAP{$ttl};

	if (uc($type) eq 'TXT') {
		$values = [ map { /^".*"$/ ? $_ : "\"$_\"" } @$values ];
	}

	my $existing = $self->getRecord($name, $type);
	if ($existing) {
		push @{$existing->values}, @$values;
	} else {
		push @{$self->{__records}}, BCXS::DNS::RRSet->new(name => $name, type => $type, ttl => $ttl, values => $values);
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
		print "Adding SPF $name $entry\n";
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
	my ($self, $rr) = @_;
	return $self->provider->updateRecord($rr, $self);
}

sub deleteRecord {
	my ($self, $rr) = @_;
	return $self->provider->deleteRecord($rr, $self);
}

1;
