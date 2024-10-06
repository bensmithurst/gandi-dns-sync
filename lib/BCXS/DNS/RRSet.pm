package BCXS::DNS::RRSet;
use strict;

use Moose;

has name => (is => 'ro', isa => 'Str');
has type => (is => 'ro', isa => 'Str');

has ttl => (is => 'rw', isa => 'Int');
has values => (is => 'rw', isa => 'ArrayRef[Str]');

has zone => (is => 'ro', isa => 'BCXS::DNS::Zone');

sub equals {
	my ($self, $other) = @_;

	return 0 unless lc($self->name) eq lc($other->name);
	return 0 unless lc($self->type) eq lc($other->type);
	return 0 unless $self->ttl == $other->ttl;

	my $uniqueSeparator = '__';

	return join($uniqueSeparator, sort @{$self->values}) eq join($uniqueSeparator, sort @{$other->values});
}

sub getFQDN {
	my ($self) = @_;

	if ($self->name eq '@') {
		return $self->zone->fqdn;
	}

	return sprintf('%s.%s', $self->name, $self->zone->fqdn);
}

1;
