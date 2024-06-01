#!/usr/bin/perl

use strict;
use warnings;

use FindBin qw($Bin);

require "$Bin/common.pl";

init();
main();

my (%domains, %domainRecords);

sub main {
	foreach my $row (@{request('GET', 'livedns/domains')}) {
		$domains{$row->{fqdn}} = 1;
	}

	foreach my $file (glob('/home/opnsense/*.conf')) {
		importFile($file);
	}

}

sub importFile {
	my ($file) = @_;

	my $fh = IO::File->new($file, 'r') or die $!;
	my %seen;

	while (defined(my $line = $fh->getline())) {
		next unless $line =~ /^local-data: "(\S+)\s+(?:\S+\s+)?(\S+)\s+(\S+)"/;

		my ($name, $type, $value) = ($1, $2, $3);

		next if $seen{$name}{$type}++;

		next unless $name =~ /\./;

		createRecord($name, $type, $value);
	}

}

sub createRecord {
	my ($fqdn, $type, $value) = @_;

	my $rrset = {
		rrset_ttl => 3600,
		rrset_values => [ $value ],
	};

	my ($name, $domain) = findNameAndDomain($fqdn);

	if (!$domainRecords{$domain}) {
		foreach my $record (@{request('GET', "livedns/domains/$domain/records")}) {
			$domainRecords{$domain}{$record->{rrset_name}}{$record->{rrset_type}} = $record;
		}
	}

	my $existing = $domainRecords{$domain}{$name}{$type};
	if (!$existing || recordHasChanged($existing, $rrset)) {
		print "Creating $name.$domain  $type  $value\n";
		request('PUT', "livedns/domains/$domain/records/$name/$type", $rrset);
	}

}

sub findNameAndDomain {
	my ($input) = @_;

	my $name = '@';
	my $domain = lc $input;

	until ($domains{$domain}) {
		if ($domain =~ /^([^.]+)\.(.*)$/) {
			my $nameComponent = $1;
			$domain = $2;

			if ($name eq '@') {
				$name = $nameComponent;
			} else {
				$name = "$name.$nameComponent";
			}
		} else {
			die "failed at $name/$domain";
		}
	}

	return ($name, $domain);
}

sub recordHasChanged {
	my ($first, $second) = @_;

	return 1 if $first->{rrset_ttl} != $second->{rrset_ttl};

	my $firstValues = join(',', sort @{$first->{rrset_values}});
	my $secondValues = join(',', sort @{$second->{rrset_values}});

	return $firstValues ne $secondValues;
}
