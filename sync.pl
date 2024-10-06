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

	my $localZone = loadZone($fqdn);

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

sub loadZone {
	my ($fqdn) = @_;

	my $zone = BCXS::DNS::Zone->new(fqdn => $fqdn);

	$zone->addIgnoredName('@', 'NS');
	loadFileRecursively($fqdn, "domains/$fqdn.yaml", $zone);

	$zone->finalizeSPF();

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

	$zone->addSPF($spfRR);

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
