#!/bin/sh

install -dm 755 /opt/dns-sync/bin /opt/dns-sync/lib/BCXS/DNS/Provider
install -cm 555 sync.pl /opt/dns-sync/dns-sync
install -cm 444 lib/BCXS/DNS/Provider/*.pm /opt/dns-sync/lib/BCXS/DNS/Provider
install -cm 444 lib/BCXS/DNS/*.pm /opt/dns-sync/lib/BCXS/DNS
ln -sf /opt/dns-sync/dns-sync /usr/local/bin/dns-sync
