#!/usr/bin/env bash
# One-time setup: install a self-signed code-signing certificate into a
# dedicated, always-unlocked keychain so the XCUITest runner can be signed
# with a stable identity over SSH (the host runs xcodebuild on the VM via
# ssh; the SSH session can't access the user's GUI-locked login keychain).
#
# Why this matters:
# 1. macOS TCC keys Accessibility grants by the binary's designated
#    requirement (DR). Ad-hoc signing puts the SHA-256 binary hash in the
#    DR, so every rebuild — even comment-only — invalidates the previous
#    grant and the next run fails with "Timed out while enabling automation
#    mode". A stable cert puts the cert's identity in the DR, so the grant
#    survives any rebuild.
# 2. Login keychain unlock state doesn't cross between launchd domains, so
#    a key in login.keychain that's accessible from a GUI Terminal session
#    is invisible to xcodebuild running over SSH (codesign returns
#    errSecInternalComponent). A separate keychain that we never lock works
#    in both contexts.
#
# The dedicated keychain (NPP-HexEdit-Codesign.keychain-db) has a fixed
# password (npp-hexedit-test) and is added to the user's keychain search
# list. The password is in cleartext both here and in vm-test.sh because
# the keychain only ever holds a self-signed local-test cert that signs
# the test runner — leaking the password leaks nothing useful. Anything
# signed with the cert works from any session (GUI Terminal, SSH-spawned
# xcodebuild, etc.) once vm-test.sh has unlocked the keychain in that
# session's launchd domain.
#
# Run once per machine that builds the runner (the VM in our standard
# workflow). Must be run in a Terminal *inside* the VM — the trust step
# at the end shows a GUI prompt that an SSH session can't approve.
# Idempotent — re-running just reports the existing cert.
#
# See macos/TESTING.md "One-time setup: stable code-signing identity for
# the test runner" for the complete procedure including troubleshooting.
#
# Usage:
#   bash ~/vm-local/NPP_HexEdit/macos/scripts/install-test-codesign-cert.sh

set -euo pipefail

CERT_NAME="NPP-HexEdit Test Codesign"
KEYCHAIN_NAME="NPP-HexEdit-Codesign.keychain-db"
KEYCHAIN_PATH="$HOME/Library/Keychains/$KEYCHAIN_NAME"
# Empty password — this keychain holds only a self-signed local-test cert
# and we want it readable from any session including SSH. macOS rejects a
# truly empty password during keychain creation, so we use a fixed string
# the script can also use to unlock if needed.
KEYCHAIN_PASS="npp-hexedit-test"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# ---- Clean up legacy install in login.keychain ---------------------------
#
# Earlier versions of this script imported into login.keychain. That works
# from a GUI session but not from xcodebuild-over-SSH (the SSH session
# can't see the unlocked login keychain). If a legacy identity is still
# there, codesign might pick it instead of the dedicated-keychain one and
# fail with errSecInternalComponent. Remove any leftover.
LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
if security find-identity -v -p codesigning "$LOGIN_KEYCHAIN" 2>/dev/null \
       | grep -q -F "$CERT_NAME"; then
    echo "==> Removing legacy '$CERT_NAME' from login.keychain"
    security delete-identity -c "$CERT_NAME" "$LOGIN_KEYCHAIN" >/dev/null 2>&1 || true
    security delete-certificate -t -c "$CERT_NAME" "$LOGIN_KEYCHAIN" >/dev/null 2>&1 || true
fi

# ---- Idempotent fast-path ------------------------------------------------

if [[ -f "$KEYCHAIN_PATH" ]] && \
   security find-identity -v -p codesigning "$KEYCHAIN_PATH" 2>/dev/null \
       | grep -q -F "$CERT_NAME"; then
    echo "==> Code-signing identity '$CERT_NAME' already present in $KEYCHAIN_NAME."
    security find-identity -v -p codesigning "$KEYCHAIN_PATH" | grep -F "$CERT_NAME"
    # Make sure it's still on the search list (a `security delete-keychain`
    # by accident would have removed it).
    if ! security list-keychains | grep -q "$KEYCHAIN_NAME"; then
        echo "==> Re-adding to keychain search list"
        EXISTING=$(security list-keychains -d user | tr -d '" ')
        security list-keychains -d user -s "$KEYCHAIN_PATH" $EXISTING >/dev/null
    fi
    exit 0
fi

# ---- Create dedicated keychain -------------------------------------------

if [[ ! -f "$KEYCHAIN_PATH" ]]; then
    echo "==> Creating $KEYCHAIN_NAME"
    security create-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN_PATH"
fi

# Disable auto-lock and lock-on-sleep so the keychain stays accessible
# from SSH-spawned xcodebuild. Passing NO flags here is critical: -l
# enables lock-on-sleep, -u enables lock-on-timeout, and -t 0 means a
# zero-second timeout (i.e. lock immediately, every time). All three
# default to off, which is exactly what we want — the keychain stays
# unlocked indefinitely after unlock-keychain.
security set-keychain-settings "$KEYCHAIN_PATH"
security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN_PATH"

# Add to the user's keychain search list (codesign / xcodebuild scan this
# list to find signing identities). Order matters; prepend so our cert is
# preferred over anything in login.keychain.
if ! security list-keychains -d user | grep -q -F "$KEYCHAIN_NAME"; then
    echo "==> Adding to keychain search list"
    EXISTING=$(security list-keychains -d user | tr -d '" ')
    security list-keychains -d user -s "$KEYCHAIN_PATH" $EXISTING >/dev/null
fi

# ---- Generate cert + key + import ----------------------------------------

echo "==> Generating self-signed code-signing certificate"

# Pin to the system openssl (LibreSSL). Homebrew's OpenSSL 3.x defaults to
# PBKDF2 + AES-256-CBC for PKCS#12 export, which macOS Security framework
# can't decrypt — manifests as "MAC verification failed (wrong password?)"
# during import.
SYSTEM_OPENSSL=/usr/bin/openssl
if [[ ! -x "$SYSTEM_OPENSSL" ]]; then
    echo "error: $SYSTEM_OPENSSL not present; system openssl is required for Keychain-compatible PKCS#12 export" >&2
    exit 2
fi

cat > "$TMPDIR/openssl.cnf" <<EOF
[req]
distinguished_name = req_distinguished_name
prompt             = no
x509_extensions    = v3_codesign

[req_distinguished_name]
CN = $CERT_NAME
O  = NPP-HexEdit Local

[v3_codesign]
basicConstraints     = CA:false
keyUsage             = critical, digitalSignature
extendedKeyUsage     = critical, codeSigning
subjectKeyIdentifier = hash
EOF

# 2048-bit RSA, valid 10 years, with the code-signing EKU.
"$SYSTEM_OPENSSL" req -new -newkey rsa:2048 -nodes -x509 -days 3650 \
    -config "$TMPDIR/openssl.cnf" \
    -keyout "$TMPDIR/codesign.key" \
    -out    "$TMPDIR/codesign.crt" 2>/dev/null

P12_PASS="$("$SYSTEM_OPENSSL" rand -hex 16)"
"$SYSTEM_OPENSSL" pkcs12 -export \
    -inkey "$TMPDIR/codesign.key" \
    -in    "$TMPDIR/codesign.crt" \
    -out   "$TMPDIR/codesign.p12" \
    -name  "$CERT_NAME" \
    -password "pass:$P12_PASS"

# Import into the dedicated keychain. -A means "any app can access the
# private key without prompting". For a self-signed local-test cert this
# is fine: the key can only sign things, and "any app on the VM can sign
# as this identity" is no worse than the ad-hoc signing it replaces. The
# tighter -T-based ACL would prompt the user to authorise codesign +
# security at import time, and that prompt can't be approved over SSH or
# scripted away.
echo "==> Importing identity into $KEYCHAIN_NAME"
security import "$TMPDIR/codesign.p12" \
    -k "$KEYCHAIN_PATH" \
    -P "$P12_PASS" \
    -A \
    >/dev/null

# -A grants the ACL "any app" but doesn't set the partition list, which
# macOS Sierra+ enforces separately. Without partition-list entries that
# include the partition codesign runs in (apple-tool: for Apple-signed
# binaries, unsigned: as a wildcard for everything else), codesign returns
# errSecInternalComponent over SSH even with the keychain unlocked. -k
# provides the keychain password non-interactively so this runs without a
# GUI prompt.
echo "==> Setting key partition list"
security set-key-partition-list \
    -S apple-tool:,apple:,codesign:,unsigned: \
    -s -k "$KEYCHAIN_PASS" \
    "$KEYCHAIN_PATH" \
    >/dev/null

# ---- Trust the cert for code signing -------------------------------------
#
# Without this, `security find-identity -p codesigning` (and xcodebuild's
# identity picker) silently hide self-signed certs. -k pins the trust to
# our dedicated keychain so it stays scoped — system-wide trust would be
# overkill for a local-test cert.
echo "==> Marking cert as trusted for code signing (Keychain Access will prompt)"
security add-trusted-cert \
    -r trustRoot \
    -p codeSign \
    -k "$KEYCHAIN_PATH" \
    "$TMPDIR/codesign.crt"

echo "==> Verifying"
if security find-identity -v -p codesigning "$KEYCHAIN_PATH" \
       | grep -q -F "$CERT_NAME"; then
    security find-identity -v -p codesigning "$KEYCHAIN_PATH" | grep -F "$CERT_NAME"
    echo
    echo "Done. Run the UI suite — the runner will be signed with this identity."
    echo "Grant Accessibility to HexEditorUITestRunner one final time on the VM"
    echo "desktop; the grant will survive all future rebuilds."
else
    echo "ERROR: cert imported but not visible to codesign — check Keychain Access" >&2
    exit 1
fi
