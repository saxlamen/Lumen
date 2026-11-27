#!/usr/bin/env bash
# Classify a macOS provisioning profile as "development" or "distribution" based
# on the certificate it embeds (the ground truth for the intended signing identity).
# Usage: profile-kind.sh <profile-path>  -> prints "development", "distribution" or "unknown"
set -euo pipefail

profile="${1:?usage: profile-kind.sh <profile-path>}"

if [ ! -f "${profile}" ]; then
    echo "unknown"
    exit 0
fi

decoded="$(mktemp "${TMPDIR:-/tmp}/macos-profile-kind.XXXXXX")"
trap 'rm -f "${decoded}"' EXIT
security cms -D -i "${profile}" > "${decoded}"

python3 - "${decoded}" <<'PY'
import subprocess
import sys
import tempfile
import os
import plistlib

d = plistlib.load(open(sys.argv[1], 'rb'))
certs = d.get('DeveloperCertificates') or []
if not certs:
    print('unknown')
    sys.exit(0)

with tempfile.NamedTemporaryFile(suffix='.der', delete=False, mode='wb') as f:
    f.write(certs[0])
    tmp = f.name
try:
    out = subprocess.run(
        ['openssl', 'x509', '-in', tmp, '-inform', 'DER', '-noout', '-subject'],
        capture_output=True, text=True)
    subject = out.stdout
finally:
    os.unlink(tmp)

if 'Apple Development' in subject:
    print('development')
elif 'Developer ID Application' in subject or 'Apple Distribution' in subject:
    print('distribution')
else:
    print('unknown')
PY
