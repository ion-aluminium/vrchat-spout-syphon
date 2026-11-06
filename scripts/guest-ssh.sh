#!/bin/bash
# guest-ssh.sh <command...> : run a command in the SteamOS guest over the launcher's SSH forward.
# Streams stdout/stderr byte-exactly (no pty translation). Password comes from the launcher's Keychain item.
set -u
PW="$(security find-generic-password -s es.fxgam.steamac.guest-password -w 2>/dev/null)"
[ -n "$PW" ] || { echo "guest-ssh: no password in Keychain" >&2; exit 1; }
ASK="$(mktemp /tmp/askpass.XXXXXX)"
printf '#!/bin/sh\nprintf "%%s\\n" "$GUEST_PW"\n' > "$ASK"; chmod 700 "$ASK"
trap 'rm -f "$ASK"' EXIT
GUEST_PW="$PW" SSH_ASKPASS="$ASK" SSH_ASKPASS_REQUIRE=force \
  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o PubkeyAuthentication=no -o PreferredAuthentications=password \
    -o NumberOfPasswordPrompts=1 -o LogLevel=ERROR \
    -p 2222 steamos@127.0.0.1 "$@"
