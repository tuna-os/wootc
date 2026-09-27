"""Bounded PE/COFF and EFI signature-list parsing for ESP chain verification.

This module parses containers only. A certificate found in a PE is never proof
of a signature: the caller must verify the Authenticode digest and signature.
"""
import struct
import uuid

MAX_IMAGE = 32 * 1024 * 1024
X509 = uuid.UUID('a5c059a1-94e4-4aa7-87b5-ab155c2bf072')
SHA256 = uuid.UUID('c1c41626-504c-4092-aca9-41f936934328')
X509_SHA256 = uuid.UUID('3bd2a492-96c0-4079-b420-fcf98ef103ed')


def region(data, offset, size):
    if offset < 0 or size < 0 or offset + size > len(data):
        raise ValueError('truncated container')
    return data[offset:offset + size]


def unpack(fmt, data, offset):
    return struct.unpack(fmt, region(data, offset, struct.calcsize(fmt)))


def der_object(data, offset=0):
    """Return (tag, content offset, end); reject noncanonical DER lengths."""
    tag, length = unpack('BB', data, offset)
    start = offset + 2
    if length & 128:
        count = length & 127
        if not 1 <= count <= 4:
            raise ValueError('invalid DER length')
        encoded = region(data, start, count)
        length = int.from_bytes(encoded, 'big')
        if encoded[0] == 0 or length < 128:
            raise ValueError('noncanonical DER length')
        start += count
    region(data, start, length)
    return tag, start, start + length


def certificate(data):
    tag, _, end = der_object(data)
    if tag != 48 or end != len(data):
        raise ValueError('invalid certificate container')
    return data


def signature_lists(data):
    """Return exact (type, signature bytes), excluding owner GUIDs.

    Entire lists must parse. Unknown types are retained for policy to reject
    or handle explicitly; partial/trailing lists never become partial trust.
    """
    out, pos = [], 0
    while pos < len(data):
        kind = uuid.UUID(bytes_le=bytes(region(data, pos, 16)))
        size, header, stride = unpack('<III', data, pos + 16)
        if size < 28 or header > size - 28 or stride <= 16:
            raise ValueError('invalid EFI signature list')
        region(data, pos, size)
        start = pos + 28 + header
        if (pos + size - start) % stride:
            raise ValueError('incomplete EFI signature entry')
        while start < pos + size:
            value = region(data, start + 16, stride - 16)
            if kind == X509:
                certificate(value)
            elif kind == SHA256 and len(value) != 32:
                raise ValueError('invalid SHA256 EFI signature')
            elif kind == X509_SHA256 and len(value) != 48:
                raise ValueError('invalid certificate revocation entry')
            out.append((kind, value))
            start += stride
        pos += size
    return out


class PE:
    def __init__(self, data):
        if len(data) > MAX_IMAGE or region(data, 0, 2) != b'MZ':
            raise ValueError('invalid PE image')
        self.data = data
        pe, = unpack('<I', data, 60)
        if region(data, pe, 4) != b'PE\0\0':
            raise ValueError('invalid PE signature')
        machine, count = unpack('<HH', data, pe + 4)
        if machine != 0x8664 or not 1 <= count <= 96:
            raise ValueError('unsupported PE architecture or section count')
        symbols, symbol_count = unpack('<II', data, pe + 12)
        optional_size, = unpack('<H', data, pe + 20)
        opt = pe + 24
        region(data, opt, optional_size)
        magic, = unpack('<H', data, opt)
        if magic != 0x20b or optional_size < 152:
            raise ValueError('unsupported PE optional header')
        dirs, = unpack('<I', data, opt + 108)
        if dirs < 5 or 112 + dirs * 8 > optional_size:
            raise ValueError('invalid PE directories')
        header_size, = unpack('<I', data, opt + 60)
        table = opt + optional_size
        region(data, table, count * 40)
        if header_size < table + count * 40:
            raise ValueError('section table outside PE headers')
        region(data, 0, header_size)
        self.checksum = opt + 64
        self.certificate_entry = opt + 112 + 4 * 8
        self.cert_offset, self.cert_size = unpack('<II', data, self.certificate_entry)
        self.sections = {}
        occupied = [(0, header_size)]
        for index in range(count):
            entry = table + index * 40
            name = region(data, entry, 8).rstrip(b'\0')
            if name.startswith(b'/'):
                if not name[1:].isdigit() or not symbols:
                    raise ValueError('invalid COFF section name')
                strings = symbols + symbol_count * 18
                strings_size, = unpack('<I', data, strings)
                string_table = region(data, strings, strings_size)
                offset = int(name[1:])
                if not 4 <= offset < len(string_table):
                    raise ValueError('invalid COFF string offset')
                suffix = string_table[offset:]
                if b'\0' not in suffix:
                    raise ValueError('unterminated COFF section name')
                name = suffix.split(b'\0', 1)[0]
            name = name.decode('ascii')
            virtual_size, = unpack('<I', data, entry + 8)
            size, offset = unpack('<II', data, entry + 16)
            body = region(data, offset, size)
            if name in self.sections:
                raise ValueError('duplicate PE section')
            if size:
                if any(offset < end and start < offset + size for start, end in occupied):
                    raise ValueError('overlapping PE sections')
                occupied.append((offset, offset + size))
            self.sections[name] = body[:min(virtual_size, size)]
        if not self.cert_offset or not self.cert_size or self.cert_offset % 8:
            raise ValueError('missing PE Authenticode signature')
        certs = region(data, self.cert_offset, self.cert_size)
        if any(self.cert_offset < end and start < self.cert_offset + self.cert_size
               for start, end in occupied):
            raise ValueError('signature overlaps PE sections')
        self.signatures = []
        pos = 0
        while pos < len(certs):
            size, revision, kind = unpack('<IHH', certs, pos)
            if size < 8 or revision != 0x200 or kind != 2:
                raise ValueError('invalid WIN_CERTIFICATE')
            self.signatures.append(region(certs, pos + 8, size - 8))
            aligned = (size + 7) & ~7
            padding = region(certs, pos + size, aligned - size)
            if padding.strip(b'\0'):
                raise ValueError('nonzero certificate alignment padding')
            pos += aligned

    def vendor_trust(self):
        body = self.sections.get('.vendor_cert', b'')
        size, denied_size, offset, denied_offset = unpack('<IIII', body, 0)
        if size == 0 or offset < 16:
            raise ValueError('shim has no vendor trust')
        allowed = region(body, offset, size)
        denied = region(body, denied_offset, denied_size)
        if denied_size and denied_offset < offset + size:
            raise ValueError('overlapping shim vendor databases')
        if allowed[:1] == b'0':
            allowed = [(X509, certificate(allowed))]
        else:
            allowed = signature_lists(allowed)
        return allowed, signature_lists(denied)

    def sbat(self):
        raw = self.sections.get('.sbat', b'').split(b'\0', 1)[0]
        if not raw:
            raise ValueError('missing SBAT')
        result = {}
        for line in raw.decode('ascii').splitlines():
            fields = line.split(',')
            if len(fields) < 2 or not fields[0] or not fields[1].isdigit():
                raise ValueError('malformed SBAT')
            if fields[0] in result or int(fields[1]) < 1:
                raise ValueError('invalid SBAT component generation')
            result[fields[0]] = int(fields[1])
        if 'sbat' not in result:
            raise ValueError('missing SBAT format generation')
        return result

    def embedded_sbat_policies(self):
        # rhboot/shim sbat_var.S format0: offsets are relative to the payload
        # header AFTER the format word, not to the beginning of the section.
        body = self.sections.get('.sbatlevel', b'')
        version, automatic, latest = unpack('<III', body, 0)
        if version != 0 or automatic < 8 or latest <= automatic:
            raise ValueError('unsupported embedded SBAT policy format')
        first, second = 4 + automatic, 4 + latest
        if first >= len(body) or second >= len(body):
            raise ValueError('truncated embedded SBAT policy')
        policies = []
        for start, end in ((first, second), (second, len(body))):
            payload = region(body, start, end - start)
            if not payload.endswith(b'\0') or b'\0' in payload[:-1]:
                raise ValueError('malformed embedded SBAT policy')
            policies.append(sbat_policy(payload[:-1]))
        return policies


def sbat_policy(raw):
    result = {}
    if not raw or len(raw) > 65536:
        raise ValueError('invalid SBAT policy length')
    for line in raw.decode('ascii').splitlines():
        fields = line.split(',')
        if (len(fields) not in (2, 3) or not fields[0] or
                not fields[1].isdigit() or not 1 <= int(fields[1]) <= 65535 or
                fields[0] in result):
            raise ValueError('malformed SBAT policy')
        if len(fields) == 3 and (fields[0] != 'sbat' or not fields[2].isdigit()):
            raise ValueError('invalid SBAT policy timestamp')
        result[fields[0]] = int(fields[1])
    if result.get('sbat') != 1:
        raise ValueError('unsupported SBAT policy generation')
    return result


def der_children(data, start, end):
    children = []
    while start < end:
        tag, content, stop = der_object(data, start)
        if stop > end:
            raise ValueError('DER child outside parent')
        children.append((tag, start, content, stop))
        start = stop
    return children


def signature_certificates(blob):
    """Extract certificates for revocation checks, never for trust decisions."""
    tag, start, end = der_object(blob)
    if tag != 48 or len(blob) - end > 7 or blob[end:].strip(b'\0'):
        raise ValueError('invalid PKCS7 container')
    outer = der_children(blob, start, end)
    if len(outer) != 2 or outer[0][0] != 6 or outer[1][0] != 160:
        raise ValueError('invalid PKCS7 ContentInfo')
    # id-signedData OID 1.2.840.113549.1.7.2.
    if blob[outer[0][2]:outer[0][3]] != bytes.fromhex('2a864886f70d010702'):
        raise ValueError('not PKCS7 SignedData')
    wrapped = der_children(blob, outer[1][2], outer[1][3])
    if len(wrapped) != 1 or wrapped[0][0] != 48:
        raise ValueError('invalid PKCS7 SignedData wrapper')
    fields = der_children(blob, wrapped[0][2], wrapped[0][3])
    if len(fields) < 4 or [x[0] for x in fields[:3]] != [2, 49, 48]:
        raise ValueError('invalid PKCS7 SignedData fields')
    if fields[-1][0] != 49 or fields[-1][2] == fields[-1][3]:
        raise ValueError('PKCS7 has no signerInfo')
    certificates = []
    for field in fields[3:-1]:
        if field[0] == 160:
            for tag, offset, _, stop in der_children(blob, field[2], field[3]):
                if tag != 48:
                    raise ValueError('unsupported PKCS7 certificate type')
                certificates.append(certificate(blob[offset:stop]))
        elif field[0] != 161:
            raise ValueError('unknown PKCS7 optional field')
    if not certificates:
        raise ValueError('PKCS7 has no certificates')
    return certificates


def certificate_tbs(cert):
    """Exact DER bytes hashed by EFI_CERT_X509_SHA256 revocations."""
    certificate(cert)
    _, start, end = der_object(cert)
    fields = der_children(cert, start, end)
    if len(fields) != 3 or [x[0] for x in fields] != [48, 48, 3]:
        raise ValueError('malformed X509 certificate')
    return cert[fields[0][1]:fields[0][3]]
