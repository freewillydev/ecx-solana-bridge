#!/bin/sh
# Linux candidate: requires a verified bubblewrap installation/user namespaces.
# The private worker will use this fixed launcher after the Linux execution gate.
set -eu
exec /usr/bin/bwrap --unshare-net --die-with-parent --ro-bind / / --dev /dev --proc /proc -- /opt/ecx-bridge/current/bin/ecx-solana-helper --config /etc/ecx-bridge/helper.json
