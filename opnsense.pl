#!/usr/bin/perl

use strict;
use warnings;

use FindBin qw($Bin);
use Net::IP;
use YAML qw(LoadFile);

require "$Bin/common.pl";

init();
exit(main());

my (%domains, %domainRecords, $config);

sub main {
	$config = LoadFile('/home/opnsense/config.yaml');

	foreach my $row (@{request('GET', 'livedns/domains')}) {
		$domains{$row->{fqdn}} = 1;
	}

	foreach my $file (glob('/home/opnsense/*.conf')) {
		importFile($file);
	}

	return 0;
}

sub importFile {
	my ($file) = @_;

	my $fh = IO::File->new($file, 'r') or die $!;
	my %seen;

	while (defined(my $line = $fh->getline())) {
		next unless $line =~ /^local-data: "(\S+)\s+(?:\S+\s+)?(\S+)\s+(\S+)"/;

		my ($name, $type, $value) = ($1, $2, $3);

		next unless $name =~ /\./;

		if (uc($type) eq 'A') {
			next if ignoreIPv4($value);
		} elsif (uc($type) eq 'AAAA') {
			next if ignoreIPv6($value);
		}

		next if $seen{$name}{$type}++;

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

my ($__ignore);

sub ignoreIPv4 {
	my ($ip) = @_;
	return __ignore($ip, 'ipv4');
}

sub ignoreIPv6 {
	my ($ip) = @_;
	return __ignore($ip, 'ipv6');
}

sub __ignore {
	my ($ip, $field) = @_;

	$ip = Net::IP->new($ip) or die $ip;

	my $type = $ip->iptype;
	return 1 if $type eq 'SHARED'; # CGNAT

	if (!$__ignore->{$field}) {
		$__ignore->{$field} = [];
		foreach my $range (@{$config->{ignore}->{$field}}) {
			push @{$__ignore->{$field}}, Net::IP->new($range) or die $range;
		}
	}

	foreach my $range (@{$__ignore->{$field}}) {
		my $result = $ip->overlaps($range);

		die sprintf('%s / %s / %s', $ip->prefix, $range->prefix, $result) unless defined $result;

		return 1 if $result != $IP_NO_OVERLAP;
	}

	return 0;
}
