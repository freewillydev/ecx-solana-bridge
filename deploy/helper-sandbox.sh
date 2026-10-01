#!/bin/sh
# Fixed helper view: no network, ledger, native RPC cookie, home or writable files.
set -eu
[ "$#" = 2 ] && [ "$1" = --config ] && [ "$2" = /etc/ecx-bridge/helper.json ] || exit 64
set -- --unshare-all --die-with-parent --new-session --ro-bind /usr /usr --symlink usr/lib /lib --dir /etc --dir /etc/ecx-bridge --proc /proc --dev /dev --ro-bind /etc/ecx-bridge/helper.json /etc/ecx-bridge/helper.json --ro-bind /opt/ecx-bridge/current/bin/ecx-solana-helper /helper
if [ -d /lib64 ]; then set -- "$@" --symlink usr/lib64 /lib64; fi
if [ -f /etc/ecx-bridge/signer.json ]; then
    set -- "$@" --ro-bind /etc/ecx-bridge/signer.json /etc/ecx-bridge/signer.json
fi
exec /opt/ecx-bridge/libexec/bwrap "$@" -- /helper --config /etc/ecx-bridge/helper.json
