#!/usr/bin/env bash
# Creates (once) a stable, local-only, self-signed code-signing identity,
# per design doc §7.2: not ad-hoc (no persistent identity -> every
# rebuild gets a new hash -> TCC audio-capture grant doesn't survive a
# rebuild), not a paid Developer ID (explicitly out of scope). Idempotent:
# if the identity already exists, this does nothing and just prints its
# name.
#
# Uses a dedicated keychain, not the login keychain. Reason: `security
# import`'s per-app ACL confirmation (and some later codesign-usage
# prompts) need a GUI Security Agent connection, which an SSH session
# doesn't have — SSH runs in a different security/audit session than the
# GUI login, so those prompts simply have nowhere to display and the
# operation fails with "User interaction is not allowed," regardless of
# flags, if run against the login keychain over SSH. A separate keychain
# we create, unlock, and explicitly grant partition-list access to
# sidesteps that entirely — the same pattern CI pipelines use to codesign
# non-interactively.
#
# The keychain's unlock state does NOT reliably persist across separate
# SSH invocations/security sessions (confirmed: codesign failed with
# errSecInternalComponent in a later, separate session even though this
# script had unlocked it moments earlier in its own session) — so
# build.sh re-unlocks it explicitly, every run, using the password this
# script persists to a 0600 file. That file protects nothing sensitive:
# this keychain holds only a locally-generated, nobody-else-trusts-it
# code-signing cert whose entire purpose is being a stable anchor, not a
# secret worth protecting behind an unrecoverable password.
set -euo pipefail

IDENTITY_NAME="SoundCast Local Signing"
CS_KEYCHAIN="$HOME/Library/Keychains/soundcast-build.keychain-db"
PASS_FILE="$HOME/.soundcast_build_keychain.pass"

if [ -f "$CS_KEYCHAIN" ] && [ -f "$PASS_FILE" ] && \
   security find-identity -p codesigning "$CS_KEYCHAIN" 2>/dev/null | grep -q "$IDENTITY_NAME"; then
  echo "Signing identity '$IDENTITY_NAME' already exists in $CS_KEYCHAIN."
  exit 0
fi

echo "Creating dedicated signing keychain and identity '$IDENTITY_NAME'..."
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# Incomplete/inconsistent prior state (e.g. keychain exists but we don't
# have its password, or vice versa) — start clean rather than guess.
if [ -f "$CS_KEYCHAIN" ] && [ ! -f "$PASS_FILE" ]; then
  echo "Found $CS_KEYCHAIN without a matching password file — recreating both."
  security delete-keychain "$CS_KEYCHAIN" 2>/dev/null || rm -f "$CS_KEYCHAIN"
fi

KC_PASS="$(openssl rand -base64 32)"
security create-keychain -p "$KC_PASS" "$CS_KEYCHAIN"
umask 077
printf '%s' "$KC_PASS" > "$PASS_FILE"
chmod 600 "$PASS_FILE"

# No auto-relock timeout, no lock-on-sleep — this still needs explicit
# unlock-keychain per run (see header), but at least won't add a timed
# relock on top of that.
security set-keychain-settings "$CS_KEYCHAIN"
security unlock-keychain -p "$KC_PASS" "$CS_KEYCHAIN"

# Add to the user's keychain search list (append, don't replace — this
# command takes the *whole* list, so we read the current one first) so
# `codesign` finds the identity here without needing `-k` everywhere.
EXISTING_KEYCHAINS="$(security list-keychains -d user | sed 's/^[[:space:]]*"//; s/"[[:space:]]*$//')"
if ! echo "$EXISTING_KEYCHAINS" | grep -qF "$CS_KEYCHAIN"; then
  # shellcheck disable=SC2086
  security list-keychains -d user -s $EXISTING_KEYCHAINS "$CS_KEYCHAIN"
fi

KEY="$WORKDIR/key.pem"
CERT="$WORKDIR/cert.pem"
P12="$WORKDIR/cert.p12"
P12_PASS="$(openssl rand -base64 24)"

# Self-signed cert, 10-year validity, Code Signing EKU — the thing TCC's
# designated-requirement anchor cares about is that *this same* key/cert
# gets reused on every build, not that it's trusted by any outside party.
openssl req -x509 -newkey rsa:2048 -keyout "$KEY" -out "$CERT" \
  -days 3650 -nodes \
  -subj "/CN=${IDENTITY_NAME}" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning"

openssl pkcs12 -export -in "$CERT" -inkey "$KEY" -out "$P12" \
  -name "$IDENTITY_NAME" -passout "pass:${P12_PASS}"

security import "$P12" -k "$CS_KEYCHAIN" -P "$P12_PASS" -A \
  -T /usr/bin/codesign -T /usr/bin/security

# Grants codesign non-interactive access to use this key — the other
# half of the CI-style fix (import's ACL and later signing-time key
# access are separate gates; both need pre-authorizing to avoid a GUI
# prompt that has nowhere to display over SSH).
security set-key-partition-list -S apple-tool:,apple:,codesign: \
  -s -k "$KC_PASS" "$CS_KEYCHAIN"

security add-trusted-cert -r trustRoot -p codeSign -k "$CS_KEYCHAIN" "$CERT" || {
  echo "Note: add-trusted-cert reported an issue (likely the same SSH-session"
  echo "trust-settings limitation) — harmless for our purposes: codesign only"
  echo "needs the private key to be usable, not the cert to be externally"
  echo "trusted. 'security find-identity -v' may undercount as a result; that's"
  echo "cosmetic, not a sign codesign itself will fail."
}

echo "Done."
security find-identity -p codesigning "$CS_KEYCHAIN" || true
