#!/usr/bin/env python3
"""Stable local development signing. Never changes certificate trust or TCC.

Initialize explicitly once with --init. The dedicated keychain stays outside the
repository and is not added to the user's keychain search list. A missing key is
an error, never a reason to silently fall back to ad-hoc signing or rotate keys.
"""
import fcntl
import json
import os
from pathlib import Path
import secrets
import shlex
import subprocess
import sys
import tempfile

STATE = Path.home() / 'Library/Application Support/ListenOverlay/Signing'
KEYCHAIN = STATE / 'development.keychain-db'
PASSWORD = STATE / 'keychain-password'
METADATA = STATE / 'identity.json'
IDENTIFIER = 'local.ethan.ListenOverlay'


def run(*args, data=None, check=True):
    result = subprocess.run(args, input=data, text=True, capture_output=True)
    if check and result.returncode:
        raise RuntimeError(result.stderr.strip() or 'Signing command failed')
    return result


def security(*args):
    # Secrets go over stdin, never into the shell, command line or build log.
    result = run('/usr/bin/security', '-i', data=shlex.join(args) + '\n')
    if 'Sec' in result.stderr and ('failed' in result.stderr or 'error' in result.stderr):
        raise RuntimeError('Dedicated signing keychain operation failed')
    return result


def initialize():
    if any(path.exists() for path in (KEYCHAIN, PASSWORD, METADATA)):
        raise RuntimeError('Signing identity already exists or setup is incomplete; refusing to replace it.')
    password = secrets.token_hex(32)
    PASSWORD.write_text(password)
    PASSWORD.chmod(0o600)
    search_list = shlex.split(run('/usr/bin/security', 'list-keychains', '-d', 'user').stdout)
    try:
        security('create-keychain', '-p', password, str(KEYCHAIN))
    finally:
        # create-keychain can append to the search list. Keep the prior list.
        run('/usr/bin/security', 'list-keychains', '-d', 'user', '-s', *search_list)
    run('/usr/bin/security', 'set-keychain-settings', '-lut', '300', str(KEYCHAIN))
    with tempfile.TemporaryDirectory(prefix='bootstrap-', dir=STATE) as folder:
        folder = Path(folder)
        config = folder / 'certificate.cnf'
        config.write_text('''[req]
distinguished_name = subject
x509_extensions = extensions
prompt = no
[subject]
CN = ListenOverlay Local Development
[extensions]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
''')
        key = folder / 'private.pem'
        cert = STATE / 'certificate.pem'
        run('/usr/bin/openssl', 'req', '-new', '-x509', '-newkey', 'rsa:3072',
            '-nodes', '-sha256', '-days', '3650', '-config', str(config),
            '-keyout', str(key), '-out', str(cert))
        p12 = folder / 'identity.p12'
        run('/usr/bin/openssl', 'pkcs12', '-export', '-inkey', str(key),
            '-in', str(cert), '-out', str(p12), '-passout', 'stdin', data=password)
        security('import', str(p12), '-k', str(KEYCHAIN), '-f', 'pkcs12',
                 '-P', password, '-x', '-T', '/usr/bin/codesign')
        security('set-key-partition-list', '-S', 'apple-tool:,codesign:', '-s',
                 '-k', password, str(KEYCHAIN))
        fingerprint = run('/usr/bin/openssl', 'x509', '-in', str(cert), '-noout',
                          '-fingerprint', '-sha1').stdout.strip().split('=')[1].replace(':', '')
        METADATA.write_text(json.dumps({'sha1': fingerprint, 'identifier': IDENTIFIER}, indent=2) + '\n')
    run('/usr/bin/security', 'lock-keychain', str(KEYCHAIN))
    print('Created persistent local signing identity (no system trust changes).')


def sign(app):
    if not all(path.is_file() for path in (KEYCHAIN, PASSWORD, METADATA)):
        raise RuntimeError('Persistent signing identity missing. Run scripts/sign_app.py --init once; do not recreate an existing identity.')
    identity = json.loads(METADATA.read_text())
    if identity['identifier'] != IDENTIFIER:
        raise RuntimeError('Unexpected signing identity')
    security('unlock-keychain', '-p', PASSWORD.read_text(), str(KEYCHAIN))
    try:
        for library in sorted((app / 'Contents/Resources/OCR').glob('*.dylib')):
            run('/usr/bin/codesign', '--force', '--sign', identity['sha1'],
                '--keychain', str(KEYCHAIN), '--timestamp=none',
                '--identifier', IDENTIFIER + '.ocr', str(library))
        run('/usr/bin/codesign', '--force', '--sign', identity['sha1'],
            '--keychain', str(KEYCHAIN), '--timestamp=none', '--identifier', IDENTIFIER, str(app))
        run('/usr/bin/codesign', '--verify', '--deep', '--strict', str(app))
        result = run('/usr/bin/codesign', '-d', '-r-', str(app))
        requirement = next(line.split('designated => ', 1)[1].strip()
                           for line in (result.stdout + result.stderr).splitlines()
                           if 'designated => ' in line)
        if 'cdhash' in requirement or ('anchor' not in requirement and 'certificate' not in requirement):
            raise RuntimeError('Signing did not produce a stable certificate-bound identity')
        recorded = STATE / 'designated-requirement.txt'
        if recorded.exists() and recorded.read_text().strip() != requirement:
            raise RuntimeError('Signing identity changed; refusing to publish this build')
        recorded.write_text(requirement + '\n')
        print('Verified stable, certificate-bound local signature.')
    finally:
        run('/usr/bin/security', 'lock-keychain', str(KEYCHAIN))


if __name__ == '__main__':
    os.umask(0o077)
    STATE.mkdir(mode=0o700, parents=True, exist_ok=True)
    with (STATE / 'signing.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            if sys.argv[1:] == ['--init']:
                initialize()
            elif len(sys.argv) == 2:
                sign(Path(sys.argv[1]).resolve(strict=True))
            else:
                raise RuntimeError('Usage: sign_app.py --init | APP_PATH')
        except Exception as error:
            print(str(error), file=sys.stderr)
            sys.exit(1)
