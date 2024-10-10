package BCXS::DNS::Provider::YAML;
use strict;

use BCXS::DNS::Common;
use Moose;
use YAML qw(LoadFile);
use UNIVERSAL::require;

sub loadZone {
	my ($self, $fqdn) = @_;

	my $zone = BCXS::DNS::Zone->new(fqdn => $fqdn);

	$zone->addIgnoredName('@', 'NS');
	$self->loadFileRecursively($fqdn, "domains/$fqdn.yaml", $zone);

	$zone->finalizeSPF();

	return $zone;
}

sub loadFileRecursively {
	my ($self, $fqdn, $file, $zone, $subdomain, $defaultTTL, $depth) = @_;

	$depth = 0 unless defined $depth;

	die if $depth > 2;

	my $data = LoadFile($file);

	if ($depth == 0) {
		my $provider = $data->{remote}->{name};
		my $class = "BCXS::DNS::Provider::$provider";
		if (!$class->require()) {
			die $@;
		}

		$zone->remote($class->new);
	}

	# TTL at the top level defines the default TTL for rows within this file, and all include files.
	if (defined $data->{ttl}) {
		$defaultTTL = $data->{ttl};
	}

	if ($data->{include}) {
		foreach my $inc (@{$data->{include}}) {
			$self->loadFileRecursively($fqdn, $inc->{file}, $zone, $inc->{subdomain}, $defaultTTL, $depth + 1);
		}
	}

	if (my $ttlMap = $data->{ttl_map}) {
		while (my ($key, $value) = each %$ttlMap) {
			print "$key/$value\n";
			$zone->addTTLMap($key, $value);
		}
	}

	if ($data->{ignore}) {
		foreach my $rr (@{$data->{ignore}}) {
			$zone->addIgnoredName($rr->{name}, $rr->{type});
		}
	}

	$self->loadSPF($zone, $data, $fqdn, $subdomain);

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

			my $ttl = $defaultTTL;
			if (defined $rr->{ttl}) {
				$ttl = $rr->{ttl};
			}

			$zone->addRecord($rr->{name}, $rr->{type}, $rr->{ttl}, $values);
		}
	}

	return;
}

sub loadSPF {
	my ($self, $zone, $data, $domain, $subdomain) = @_;

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
				$ip = BCXS::DNS::Common::resolveName('A', $ip, $domain);
			}

			$zone->addSPF($spfRR, "ip4:$ip");
		} else {
			$zone->addSPF($spfRR, $entry);
		}
	}

	return;
}

1;
