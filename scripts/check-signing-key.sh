#!/bin/bash
# Fails if the Sparkle key about to sign a release is not the key the bundle
# already trusts.
#
# Why this exists: `SUPublicEDKey` is baked into every shipped bundle and Sparkle
# has no key list, no secondary key and no overlap window (SUHost reads exactly
# one string). A release signed with the wrong key is not degraded, it is
# rejected by every installed copy, and there is no mechanism to route those
# users back to a working item -- they are stranded until they reinstall by hand.
#
# The way that happens by accident: Sparkle's key is stored in the login keychain
# under account `dev.wouter.dontmiss`, not the tooling's default `ed25519`. So
# `generate_keys` finds nothing, reports no conflict, and silently mints a new
# key. Any route to the same mistake -- a key restored to the wrong account on a
# new machine, a mistyped secret, two apps' keys swapped -- lands here too.
#
# Usage: scripts/check-signing-key.sh <path/to/App.app> [private-key-file]
#        scripts/check-signing-key.sh --print-public [private-key-file]
#   private-key-file omitted or "-" -> read the key from stdin
#
# --print-public derives and prints the key's public half and exits. Useful for
# checking by hand which bundles a key in 1Password can actually sign for; a
# public key is public, so printing it discloses nothing.
set -euo pipefail

if [ "${1:-}" = "--print-public" ]; then
  MODE=print
  KEY_FILE="${2:--}"
else
  MODE=compare
  APP="${1:?usage: check-signing-key.sh <App.app> [private-key-file]}"
  KEY_FILE="${2:--}"
fi
if [ "$MODE" = compare ]; then
  PLIST="$APP/Contents/Info.plist"
  [ -f "$PLIST" ] || { echo "No Info.plist at $PLIST" >&2; exit 1; }
  EXPECTED=$(/usr/libexec/PlistBuddy -c 'Print SUPublicEDKey' "$PLIST" 2>/dev/null) || {
    echo "No SUPublicEDKey in $PLIST -- is this a Sparkle bundle?" >&2; exit 1; }
fi

# Sparkle stores a 32-byte ed25519 seed. Deriving the public half needs real
# curve arithmetic: LibreSSL (which is what /usr/bin/openssl is on macOS) cannot
# do it, and depending on a Homebrew OpenSSL being present on a runner is a
# worse bet than 20 lines of RFC 8032. The script proves its own arithmetic
# against the RFC's test vector before trusting it, so a mismatch reported below
# is a statement about the key and not about this code.
ACTUAL=$(python3 -c '
import base64, hashlib, sys

P = 2**255 - 19
L = 2**252 + 27742317777372353535851937790883648493
D = -121665 * pow(121666, P - 2, P) % P
I = pow(2, (P - 1) // 4, P)

def recover_x(y, sign):
    xx = (y * y - 1) * pow(D * y * y + 1, P - 2, P) % P
    x = pow(xx, (P + 3) // 8, P)
    if (x * x - xx) % P: x = x * I % P
    if x % 2 != sign: x = P - x
    return x

By = 4 * pow(5, P - 2, P) % P
B = (recover_x(By, 0), By, 1, recover_x(By, 0) * By % P)

def add(p, q):
    a = (p[1] - p[0]) * (q[1] - q[0]) % P
    b = (p[1] + p[0]) * (q[1] + q[0]) % P
    c = 2 * p[3] * q[3] * D % P
    d = 2 * p[2] * q[2] % P
    return ((b - a) * (d - c) % P, (b + a) * (d + c) % P,
            (d - c) * (d + c) % P, (b - a) * (b + a) % P)

def mul(s, p):
    q = (0, 1, 1, 0)
    while s > 0:
        if s & 1: q = add(q, p)
        p = add(p, p)
        s >>= 1
    return q

def public_from_seed(seed):
    h = bytearray(hashlib.sha512(seed).digest()[:32])
    h[0] &= 248; h[31] &= 127; h[31] |= 64
    a = mul(int.from_bytes(h, "little"), B)
    zinv = pow(a[2], P - 2, P)
    x, y = a[0] * zinv % P, a[1] * zinv % P
    return int.to_bytes(y | ((x & 1) << 255), 32, "little")

# RFC 8032 section 7.1, test vector 1.
tv_seed = bytes.fromhex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")
tv_pub  = bytes.fromhex("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")
if public_from_seed(tv_seed) != tv_pub:
    sys.exit("ed25519 self-test failed; this script cannot be trusted to judge the key")

raw = base64.b64decode(sys.stdin.buffer.read().strip())
if len(raw) == 64:      # seed || public
    pub = raw[32:]
elif len(raw) == 32:    # seed only, which is what Sparkle stores
    pub = public_from_seed(raw)
else:
    sys.exit("private key is %d bytes; expected 32 or 64" % len(raw))
print(base64.b64encode(pub).decode())
' < "$([ "$KEY_FILE" = "-" ] && echo /dev/stdin || echo "$KEY_FILE")")

if [ "$MODE" = print ]; then
  echo "$ACTUAL"
  exit 0
fi

if [ "$ACTUAL" != "$EXPECTED" ]; then
  echo "REFUSING TO SIGN: the signing key does not match this bundle." >&2
  echo "  Info.plist SUPublicEDKey : $EXPECTED" >&2
  echo "  signing key's public half: $ACTUAL" >&2
  echo "" >&2
  echo "Signing with this key ships an update no installed copy can verify," >&2
  echo "and Sparkle has no way to recover those users. Check that the key came" >&2
  echo "from the right 1Password item and that nothing ran generate_keys." >&2
  exit 1
fi

echo "==> Signing key matches SUPublicEDKey ($EXPECTED)"
