package BCXS::DNS::RRSet;
use strict;

use Moose;

has name => (is => 'ro', isa => 'Str');
has type => (is => 'ro', isa => 'Str');

has ttl => (is => 'rw', isa => 'Int');
has values => (is => 'rw', isa => 'ArrayRef[Str]');

sub equals {
	my ($self, $other) = @_;

	print Data::Dumper::Dumper([$self, $other]);

	return 0 unless lc($self->name) eq lc($other->name);
	return 0 unless lc($self->type) eq lc($other->type);
	return 0 unless $self->ttl == $other->ttl;

	my $uniqueSeparator = '__';

	return join($uniqueSeparator, sort @{$self->values}) eq join($uniqueSeparator, sort @{$other->values});
}

1;
