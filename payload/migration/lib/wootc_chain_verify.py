"""Role-specific Authenticode and revocation preflight for a frozen EFI trio."""
import base64
import hashlib
import os
import re
import struct
import subprocess
import tempfile
from pathlib import Path
from wootc_pe import (PE, X509, SHA256, X509_SHA256, signature_lists,
                     signature_certificates, certificate_tbs, sbat_policy)

GLOBAL = '8be4df61-93ca-11d2-aa0d-00e098032b8c'
DB_GUID = 'd719b2cb-3d3a-4596-a3bc-dad00e67656f'
SHIM_GUID = '605dab50-e046-4300-abb6-3dd810dd8b23'
FILES = ('shimx64.efi', 'grubx64.efi', 'mmx64.efi')


def efi_variable(directory, name, guid, optional=False):
    try:
        raw = (directory / (name + '-' + guid)).read_bytes()
    except FileNotFoundError:
        if optional:
            return b''
        raise ValueError('required EFI variable missing: ' + name)
    if len(raw) < 4 or len(raw) > 1024 * 1024:
        raise ValueError('invalid EFI variable length: ' + name)
    attrs, = struct.unpack_from('<I', raw)
    if not attrs & 2 or attrs & ~0x7f:
        raise ValueError('invalid EFI variable attributes: ' + name)
    return raw[4:]


def checked_database(raw):
    records = signature_lists(raw)
    if any(kind not in (X509, SHA256, X509_SHA256) for kind, _ in records):
        raise ValueError('unsupported EFI trust/revocation entry type')
    return records


class Verifier:
    def __init__(self, closure):
        self.closure = Path(closure)

    def run(self, executable, *args):
        # Invoke the packaged ELF loader, so targets never resolve the build's
        # libcrypto against a different distribution's ABI.
        env = dict(os.environ)
        for key in ('LD_PRELOAD', 'LD_AUDIT', 'LD_LIBRARY_PATH'):
            env.pop(key, None)
        env['OPENSSL_CONF'] = '/dev/null'
        env['OPENSSL_MODULES'] = str(self.closure / 'disabled-modules')
        command = [str(self.closure / 'ld-linux-x86-64.so.2'), '--library-path',
                   str(self.closure), str(self.closure / executable), *map(str, args)]
        return subprocess.run(command, env=env, capture_output=True, timeout=30)

    def digest(self, path):
        proc = self.run('sbpehash', path)
        if proc.returncode or not re.fullmatch(rb'[0-9a-f]{64}\n', proc.stdout):
            raise ValueError('PE Authenticode digest failed: ' + path.name)
        return bytes.fromhex(proc.stdout.decode().strip())

    def authenticate(self, path, anchors):
        if not anchors:
            raise ValueError('no exact certificate trust anchor for ' + path.name)
        with tempfile.TemporaryDirectory(prefix='wootc-cert-') as temp:
            cert = Path(temp) / 'anchor.pem'
            for anchor in anchors:
                encoded = base64.b64encode(anchor).decode()
                cert.write_text('-----BEGIN CERTIFICATE-----\n' +
                                '\n'.join(encoded[i:i+64] for i in range(0, len(encoded), 64)) +
                                '\n-----END CERTIFICATE-----\n')
                if self.run('sbverify', '--cert', cert, path).returncode == 0:
                    return hashlib.sha256(anchor).hexdigest()
        raise ValueError('Authenticode digest/signature or signer trust refused: ' + path.name)

    def check_revocations(self, path, pe, databases):
        certificates = []
        for signature in pe.signatures:
            certificates.extend(signature_certificates(signature))
        tbs_hashes = {hashlib.sha256(certificate_tbs(cert)).digest() for cert in certificates}
        digest = self.digest(path)
        for kind, entry in databases:
            if ((kind == SHA256 and entry == digest) or
                    (kind == X509 and entry in certificates) or
                    (kind == X509_SHA256 and entry[:32] in tbs_hashes)):
                # Treat dated certificate revocations conservatively, without
                # trusting an unverified PKCS7 timestamp to bypass dbx.
                raise ValueError('EFI image/certificate is revoked: ' + path.name)


def check_sbat(image, policies):
    components = image.sbat()
    for policy in policies:
        for name, generation in policy.items():
            if name in components and components[name] < generation:
                raise ValueError('SBAT component revoked: ' + name)


def verify_transition(current, candidate, efivars, closure):
    """Prove all publication/rollback mixtures before any ESP write.

    Sources must be frozen by the caller. Authentication is never inferred
    from a filename, certificate issuer text, package version, or boot status.
    """
    current, candidate, efivars = map(Path, (current, candidate, efivars))
    for name in ('SecureBoot', 'SetupMode'):
        value = efi_variable(efivars, name, GLOBAL)
        if value not in (b'\0', b'\1'):
            raise ValueError('unknown EFI state: ' + name)
        if name == 'SetupMode' and value != b'\0':
            raise ValueError('firmware is in SetupMode')
    db = checked_database(efi_variable(efivars, 'db', DB_GUID))
    anchors = [value for kind, value in db if kind == X509]
    dbx = checked_database(efi_variable(efivars, 'dbx', DB_GUID))
    mokx = checked_database(efi_variable(efivars, 'MokListXRT', SHIM_GUID, optional=True))
    policy_raw = efi_variable(efivars, 'SbatLevelRT', SHIM_GUID)
    if policy_raw.endswith(b'\0'):
        policy_raw = policy_raw[:-1]
    policies = [sbat_policy(policy_raw)]
    verifier = Verifier(closure)
    bundles = []
    for directory in (current, candidate):
        paths = {name: directory / name for name in FILES}
        images = {name: PE(path.read_bytes()) for name, path in paths.items()}
        shim = images['shimx64.efi']
        verifier.authenticate(paths['shimx64.efi'], anchors)
        allowed, denied = shim.vendor_trust()
        allowed, denied = checked_database_entries(allowed), checked_database_entries(denied)
        vendor_anchors = [value for kind, value in allowed if kind == X509]
        if not vendor_anchors:
            raise ValueError('authenticated shim has no supported vendor certificate')
        policies.extend(shim.embedded_sbat_policies())
        bundles.append((paths, images, vendor_anchors, denied))
    # Both shims must accept both generations of both companions. Also check
    # revocations/policies that either shim can ratchet before a later rollback.
    all_denied = dbx + mokx + [entry for bundle in bundles for entry in bundle[3]]
    for paths, images, _, _ in bundles:
        for name in FILES:
            check_sbat(images[name], policies)
            verifier.check_revocations(paths[name], images[name], all_denied)
        for other in bundles:
            for name in ('grubx64.efi', 'mmx64.efi'):
                verifier.authenticate(paths[name], other[2])
    for name in FILES:
        before, after = bundles[0][1][name].sbat(), bundles[1][1][name].sbat()
        for component, generation in before.items():
            if component not in after or after[component] < generation:
                raise ValueError('SBAT component missing/downgraded: ' + component)
    return {'schemaVersion': 1, 'verified': True,
            'current': {n: hashlib.sha256((current / n).read_bytes()).hexdigest() for n in FILES},
            'candidate': {n: hashlib.sha256((candidate / n).read_bytes()).hexdigest() for n in FILES}}


def checked_database_entries(records):
    if any(kind not in (X509, SHA256, X509_SHA256) for kind, _ in records):
        raise ValueError('unsupported shim vendor database entry type')
    return records
