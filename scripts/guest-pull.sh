#!/bin/bash
# guest-pull.sh <guest-path> <local-dest> : copy a file out of the SteamOS guest.
set -u
PW="$(security find-generic-password -s es.fxgam.steamac.guest-password -w 2>/dev/null)"
[ -n "$PW" ] || { echo "no guest password in Keychain" >&2; exit 1; }
ASK="$(mktemp /tmp/askpass.XXXXXX)"; printf '#!/bin/sh\nprintf "%%s\\n" "$GUEST_PW"\n' > "$ASK"; chmod 700 "$ASK"
trap 'rm -f "$ASK"' EXIT
GUEST_PW="$PW" SSH_ASKPASS="$ASK" SSH_ASKPASS_REQUIRE=force scp -q \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PubkeyAuthentication=no \
  -o PreferredAuthentications=password -o NumberOfPasswordPrompts=1 -o LogLevel=ERROR \
  -P 2222 "steamos@127.0.0.1:$1" "$2"
