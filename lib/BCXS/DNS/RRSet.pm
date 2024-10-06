package BCXS::DNS::RRSet;
use strict;

use Moose;

has name => (is => 'ro', isa => 'Str');
has type => (is => 'ro', isa => 'Str');

has ttl => (is => 'rw', isa => 'Int');
has values => (is => 'rw', isa => 'ArrayRef[Str]');

1;
