#!/usr/bin/perl

use strict;
use warnings;

use FindBin qw($Bin);
use lib "$Bin/lib";

use Data::Dumper;
use English qw(-no_match_vars);
use Getopt::Std;
use IO::Dir;
use JSON;
use Net::DNS::Resolver;
use Readonly;
use Socket;
use Text::Diff;
use Text::Glob qw(match_glob);

use BCXS::DNS::Provider::Gandi;
use BCXS::DNS::Provider::Porkbun;
use BCXS::DNS::Provider::YAML;
use BCXS::DNS::Zone;

Readonly my $SHORT => 300;
Readonly my $MEDIUM => 3600;
Readonly my $LONG => 86400;

my $ua;

require "$Bin/common.pl";

my $yaml = BCXS::DNS::Provider::YAML->new;
my $gandi = BCXS::DNS::Provider::Gandi->new;

my %opts;
getopts('y', \%opts) or die;

main();

# Sync DNS entries for every domain with a domains/$fqdn.yaml file.
sub main {
	init();

	my $dir = IO::Dir->new('domains') or die "cannot opendir domains: $ERRNO";
	while (defined (my $file = $dir->read())) {
		next unless $file =~ /(.*)\.yaml$/i;
		my $fqdn = $1;

		eval {
			syncDomain($fqdn);
		};
		if (my $evalError = $EVAL_ERROR) {
			print $evalError;
		}
	}

	return;
}

sub syncDomain {
	my ($fqdn) = @_;

	my $localZone = $yaml->loadZone($fqdn);

	my $remoteZone = $gandi->loadZone($fqdn);

	foreach my $rr ($localZone->getRecords()) {
		my $other = $remoteZone->getRecord($rr->name, $rr->type);

		if (!$other) {
			$remoteZone->createRecord($rr);
		} elsif (!$other->equals($rr)) {
			$remoteZone->updateRecord($rr);
		}
	}

	foreach my $rr ($remoteZone->getRecords()) {
		if (!$localZone->getRecord($rr->name, $rr->type) && !$localZone->isIgnored($rr->name, $rr->type)) {
			$remoteZone->deleteRecord($rr);
		}
	}

	return;
}
