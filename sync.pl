#!/usr/bin/perl

use strict;
use warnings;

use FindBin qw($RealBin);
use lib "$RealBin/lib";

use English qw(-no_match_vars);
use IO::Dir;

use BCXS::DNS::Provider::YAML;
use BCXS::DNS::Zone;

my $yaml = BCXS::DNS::Provider::YAML->new;

main();

# Sync DNS entries for every domain with a domains/$fqdn.yaml file.
sub main {
	$OUTPUT_AUTOFLUSH = 1;

	my $dir = IO::Dir->new('domains') or die "cannot opendir domains: $ERRNO";
	while (defined (my $file = $dir->read())) {
		next unless $file =~ /(.*)\.yaml$/i;
		my $fqdn = $1;

		eval {
			syncDomain($fqdn);
		};
		if (my $evalError = $EVAL_ERROR) {
			print "Failed to sync $fqdn: $evalError\n";
		}
	}

	return;
}

sub syncDomain {
	my ($fqdn) = @_;

	my $localZone = $yaml->loadZone($fqdn);

	my $remoteZone = $localZone->remote->loadZone($fqdn);

	foreach my $rr ($localZone->getRecords()) {
		my $other = $remoteZone->getRecord($rr->name, $rr->type);

		if (!$other) {
			$remoteZone->createRecord($rr);
		} elsif (!$other->equals($rr)) {
			$remoteZone->updateRecord($rr, $other);
		}
	}

	foreach my $rr ($remoteZone->getRecords()) {
		if (!$localZone->getRecord($rr->name, $rr->type) && !$localZone->isIgnored($rr->name, $rr->type)) {
			$remoteZone->deleteRecord($rr);
		}
	}

	return;
}
