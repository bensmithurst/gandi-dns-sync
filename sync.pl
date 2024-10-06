#!/usr/bin/perl

use strict;
use warnings;

use FindBin qw($Bin);
use lib "$Bin/lib";

use Data::Dumper;
use English qw(-no_match_vars);
use Getopt::Std;
use HTTP::Status qw(HTTP_NOT_FOUND);
use IO::Dir;
use JSON;
use Net::DNS::Resolver;
use Readonly;
use Socket;
use Text::Diff;
use Text::Glob qw(match_glob);
use YAML qw(LoadFile);

use BCXS::DNS::Provider::Gandi;
use BCXS::DNS::Provider::Porkbun;
use BCXS::DNS::Zone;

Readonly my $SHORT => 300;
Readonly my $MEDIUM => 3600;
Readonly my $LONG => 86400;

my $ua;
my $resolver = Net::DNS::Resolver->new;

require "$Bin/common.pl";

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

		#createDomain($fqdn); TODO: where to create?
		eval {
			syncDomain($fqdn);
		};
		if (my $evalError = $EVAL_ERROR) {
			print $evalError;
		}
	}

	return;
}

# Create domain in LiveDNS if it doesn't already exist.
sub createDomain {
	my ($fqdn) = @_;

	my $existing = rawRequest('GET', "livedns/domains/$fqdn");
	if ($existing->code == HTTP_NOT_FOUND) {
		print "Trying to add $fqdn into LiveDNS...\n";
		request('POST', 'livedns/domains', { fqdn => $fqdn });
	} elsif (!$existing->is_success) {
		die "Querying $fqdn failed: ".$existing->as_string();
	}

	return;
}


sub syncDomain {
	my ($fqdn) = @_;

	my $localData = loadZone($fqdn);

	my $remoteData = $gandi->loadZone($fqdn);

	if ($localData->{__ignore}) {
		foreach my $ignoredRR (@{$localData->{__ignore}}) {
			if ($ignoredRR =~ /(.*\*.*)\/(.*)/) {
				my ($ignoreName, $ignoreType) = ($1, $2);

				while (my ($rrKey, $rr) = each %$remoteData) {
					next unless $rrKey =~ /(.*)\/(.*)/;
					my ($rrName, $rrType) = ($1, $2);

					next unless $rrType eq $ignoreType;

					if (match_glob($ignoreName, $rrName) && !exists $localData->{$rrKey}) {
						$localData->{$rrKey} = $remoteData->{$rrKey};
					}

				}
			} elsif ($remoteData->{$ignoredRR}) {
				$localData->{$ignoredRR} = $remoteData->{$ignoredRR};
			}
		}
		delete $localData->{__ignore};
	}

	my @allKeys = (keys(%$localData), keys(%$remoteData));
	my %allKeys = map { $_ => 1 } @allKeys;
	my $changed;

	my (@delete, @create, @update);
	foreach my $key (sort keys %allKeys) {
		if ($localData->{$key} && $remoteData->{$key}) {
			my $rr = $localData->{$key};
			if (__rrsetsDiffer($rr, $remoteData->{$key})) {
				push @update, ["livedns/domains/$fqdn/records/$rr->{rrset_name}/$rr->{rrset_type}", $rr];
				#$changed = 1;
			}
		} elsif ($localData->{$key}) {
			push @create, ["livedns/domains/$fqdn/records", $localData->{$key}];
			#$changed = 1;
		} else {
			my $rr = $remoteData->{$key};
			push @delete, ["livedns/domains/$fqdn/records/$rr->{rrset_name}/$rr->{rrset_type}"];
			#$changed = 1;
		}
	}

	foreach my $delete (@delete) {
		promptRequest('DELETE', @$delete);
	}

	foreach my $update (@update) {
		promptRequest('PUT', @$update);
	}

	foreach my $create (@create) {
		promptRequest('POST', @$create);
	}

	if ($changed) {
		my @local = sort(__flattenZone($localData));
		my @remote = sort(__flattenZone($remoteData));
		print diff(\@remote, \@local);

		promptRequest('PUT', "livedns/domains/$fqdn/records", { items => [ values %$localData ] });
		# if No, should allow making individual changes?

		loadRemoteZone($fqdn) if $changed;
	}

	return;
}

sub loadZone {
	my ($fqdn) = @_;

	my $zone = BCXS::DNS::Zone->new(fqdn => $fqdn);

	$zone->addIgnoredName('@', 'NS');
	loadFileRecursively($fqdn, "domains/$fqdn.yaml", $zone);

	return $zone;
}

sub loadFileRecursively {
	my ($fqdn, $file, $zone, $subdomain, $depth) = @_;

	$depth = 0 unless defined $depth;

	die if $depth > 2;

	my $data = LoadFile($file);

	if ($data->{include}) {
		foreach my $inc (@{$data->{include}}) {
			loadFileRecursively($fqdn, $inc->{file}, $zone, $inc->{subdomain}, $depth + 1);
		}

	}

	if ($data->{ignore}) {
		foreach my $ignoredRR (@{$data->{ignore}}) {
			my $name = $ignoredRR;
			if ($subdomain) {
				$name =~ s#/#.$subdomain/#;
			}

			$zone->addIgnoredName($name);
		}
	}

	loadSPF($zone, $data, $fqdn, $subdomain);

	if ($data->{records}) {
		my @records;
		foreach my $rr (@{$data->{records}}) {
			if ($subdomain) {
				if ($rr->{name} eq '@') {
					$rr->{name} = $subdomain;
				} else {
					$rr->{name} .= ".$subdomain";
				}
			}

			for (my $i = 0; defined $rr->{values}->[$i]; $i++) {
				$rr->{values}->[$i] =~ s/\$domain\b/$fqdn/i;
			}

			if ($rr->{name} =~ /^(.*?)(\d+)\.\.(\d+)(.*)$/) {
				my ($pre, $low, $high, $suf) = ($1, $2, $3, $4);
				foreach my $n ($low .. $high) {
					my %copy = %$rr;
					$copy{name} = $pre.$n.$suf;
					$copy{value} =~ s/\$/$n/;
					push @records, \%copy;
				}
			} else {
				push @records, $rr;
			}
		}
		foreach my $rr (@records) {
			my $values = [];
			if ($rr->{value}) {
				push @$values, $rr->{value};
			} else {
				push @$values, @{$rr->{values}};
			}

			$zone->addRecord($rr->{name}, $rr->{type}, $rr->{ttl}, $values);
		}
	}

	return;
}

sub loadSPF {
	my ($zone, $data, $domain, $subdomain) = @_;

	return unless $data->{spf};

	my $spfRR = $subdomain // '@';

	foreach my $entry (@{$data->{spf}}) {
		next unless defined $entry;

		if ($entry =~ /^ip4:(.*)/) {
			my $ip = $1;

			# crude IP check
			unless ($ip =~ /^[\d\.]+$/) {
				# assume hostname
				$ip = __resolveName('A', $ip, $domain);
			}

			$zone->addSPF($spfRR, "ip4:$ip");
		} else {
			$zone->addSPF($spfRR, $entry);
		}
	}

	return;
}

sub addRecord {
	my ($domain, $data, $name, $ttl, $type, $values) = @_;

	my $rrs = __rrset($name, $ttl, $type, $values, $domain);

	foreach my $rr (@$rrs) {
		my $key = $rr->{rrset_name}.'/'.$rr->{rrset_type};

		if (my $existing = $data->{$key}) {
			push @{$rr->{rrset_values}}, @{$existing->{rrset_values}};
		}

		$data->{$key} = $rr;
	}

	return;
}

sub promptRequest {
	my ($method, $path, $data) = @_;

	print "--------------\n";
	print "$method $path";
	if (defined $data) {
		my $encoded = encode_json($data);
		$encoded = substr($encoded, 0, 200).'...' if length($encoded) > 200;
		print " with data: $encoded";
	}
	print "\n";
	return request($method, $path, $data) if $opts{y};

	print "--- Execute? [y/N] ";

	my $answer = <STDIN>;
	if ($answer && $answer =~ /^y/i) {
		return request($method, $path, $data);
	}

	print "SKIPPED\n\n";
	sleep 1;
	return;
}

sub __rrsetsDiffer {
	my ($localRR, $remoteRR) = @_;

	return 1 if $localRR->{rrset_ttl} != $remoteRR->{rrset_ttl};

	my @localVal = sort @{$localRR->{rrset_values}};
	my @remoteVal = sort @{$remoteRR->{rrset_values}};

	while (@localVal && @remoteVal) {
		my $localVal = shift @localVal;
		my $remoteVal = shift @remoteVal;

		return 1 if $localVal ne $remoteVal;
	}

	return (scalar(@localVal) != scalar(@remoteVal));
}

sub __rrset {
	my ($name, $ttl, $type, $values, $domain) = @_;

	my @rrs;
	$values = [ $values ] if !ref $values;

	if ($type eq 'TXT') {
		$values = [ map { /^".*"$/ ? $_ : "\"$_\"" } @$values ];
	} elsif ($type =~ /^ALIAS(.*)/) {
		my $type = $1;
		my @types = ('A', 'AAAA');

		if ($type =~ m#^/(\w+)$#) {
			@types = ($1);
		}

		foreach my $type (@types) {
			my @resolved = grep { defined $_ } map { __resolveName($type, $_, $domain) } @$values;
			if (@resolved) {
				push @rrs, @{__rrset($name, $ttl, $type, @resolved, $domain)};
			}
		}
		die "Cannot find any records for alias $name in $domain" unless @rrs;
		return \@rrs;
	}

	if (defined $ttl) {
		if ($ttl eq 'SHORT') {
			$ttl = $SHORT;
		} elsif ($ttl eq 'MEDIUM') {
			$ttl = $MEDIUM;
		} elsif ($ttl eq 'LONG') {
			$ttl = $LONG;
		}
	} else {
		$ttl = $MEDIUM;
	}

	push @rrs, {
		rrset_name => $name,
		rrset_ttl => $ttl,
		rrset_type => $type,
		rrset_values => $values,
	};

	return \@rrs;
}

my %answerForName;
sub __resolveName {
	my ($type, $name, $domain) = @_;

	$name .= ".$domain" unless $name =~ /\.$/;

	if (!defined $answerForName{$name}{$type}) {
		my $res = $resolver->query("$name.", $type);
		if (!defined $res) {
			$answerForName{$name}{$type} = [];
		} else {
			$answerForName{$name}{$type} = [ $res->answer ];
		}
	}

	foreach my $rr (@{$answerForName{$name}{$type}}) {
		if ($rr->type eq $type) {
			# TODO: multiple answers?
			if ($type eq 'AAAA') {
				return $rr->address_short;
			}
			return $rr->address;
		}
	}

	return undef;
}

sub __flattenZone {
	my ($data) = @_;

	my @list;

	foreach my $key (sort keys %$data) {
		my $rr = $data->{$key};
		foreach my $val (sort @{$rr->{rrset_values}}) {
			push @list, "$rr->{rrset_name} $rr->{rrset_ttl} $rr->{rrset_type} $val\n";
		}
	}

	return @list;
}
