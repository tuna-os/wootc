#!/usr/bin/env python3
"""Container validation; cryptographic verification is tested separately."""
import importlib.util
import struct
import unittest
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('wootc_pe', ROOT / 'payload/migration/lib/wootc_pe.py')
p = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p)


def image():
    data = bytearray(0x410)
    data[:2] = b'MZ'
    struct.pack_into('<I', data, 60, 0x80)
    data[0x80:0x84] = b'PE\0\0'
    struct.pack_into('<HH', data, 0x84, 0x8664, 1)
    struct.pack_into('<H', data, 0x94, 240)
    struct.pack_into('<H', data, 0x98, 0x20b)
    struct.pack_into('<I', data, 0x98 + 60, 0x200)
    struct.pack_into('<I', data, 0x98 + 108, 16)
    struct.pack_into('<II', data, 0x98 + 144, 0x400, 16)
    section = 0x98 + 240
    data[section:section + 8] = b'.sbat\0\0\0'
    body = b'sbat,1,SBAT\nshim,4,vendor\n'
    struct.pack_into('<I', data, section + 8, len(body))
    struct.pack_into('<II', data, section + 16, 0x200, 0x200)
    data[0x200:0x200 + len(body)] = body
    struct.pack_into('<IHH', data, 0x400, 12, 0x200, 2)
    data[0x408:0x40c] = b'fake'  # A container is explicitly not a signature proof.
    return data


def esl(kind, value):
    return kind.bytes_le + struct.pack('<III', 28 + 16 + len(value), 0, 16 + len(value)) + bytes(16) + value


class ContainerTests(unittest.TestCase):
    def test_parses_generation_but_never_claims_signature_verified(self):
        obj = p.PE(image())
        self.assertEqual(obj.sbat()['shim'], 4)
        self.assertEqual(obj.signatures, [b'fake'])
        self.assertFalse(hasattr(obj, 'verified'))

    def test_every_image_truncation_is_rejected(self):
        data = image()
        for end in range(len(data)):
            with self.subTest(end=end), self.assertRaises(ValueError):
                p.PE(data[:end])

    def test_wrong_pe_architecture_rejected(self):
        data = image()
        struct.pack_into('<H', data, 0x84, 0xaa64)
        with self.assertRaises(ValueError): p.PE(data)

    def test_signature_overlapping_section_rejected(self):
        data = image()
        struct.pack_into('<II', data, 0x98 + 144, 0x200, 16)
        with self.assertRaises(ValueError): p.PE(data)

    def test_signature_alignment_padding_cannot_hide_bytes(self):
        data = image(); data[-1] = 1
        with self.assertRaises(ValueError): p.PE(data)

    def test_header_section_overlap_rejected(self):
        data = image()
        struct.pack_into('<I', data, 0x98 + 240 + 20, 0x100)
        with self.assertRaises(ValueError): p.PE(data)

    def test_unknown_optional_header_rejected(self):
        data = image()
        struct.pack_into('<H', data, 0x98, 0x10b)
        with self.assertRaises(ValueError): p.PE(data)

    def test_missing_signature_rejected(self):
        data = image()
        struct.pack_into('<II', data, 0x98 + 144, 0, 0)
        with self.assertRaises(ValueError): p.PE(data)

    def test_invalid_sbat_rejected(self):
        data = image(); data[0x200:0x200 + 24] = b'sbat,1,SBAT\nshim,nope,x\n\0'
        with self.assertRaises(ValueError): p.PE(data).sbat()

    def test_signature_lists_do_not_accept_partial_trust(self):
        data = esl(p.SHA256, bytes(32))
        self.assertEqual(p.signature_lists(data), [(p.SHA256, bytes(32))])
        for end in range(1, len(data)):
            with self.subTest(end=end), self.assertRaises(ValueError):
                p.signature_lists(data[:end])
        with self.assertRaises(ValueError): p.signature_lists(data + b'x')

    def test_esl_bad_stride_and_header_rejected(self):
        for field, value in ((16, 27), (20, 500), (24, 16), (24, 49)):
            data = bytearray(esl(p.SHA256, bytes(32)))
            struct.pack_into('<I', data, field, value)
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                p.signature_lists(data)

    def test_der_indefinite_noncanonical_and_trailing_rejected(self):
        for data in (b'0\x80', b'0\x81\x01x', b'0\x82\x00\x80' + bytes(128), b'0\x01xx'):
            with self.subTest(data=data[:8]), self.assertRaises(ValueError):
                p.certificate(data)

    def test_embedded_sbat_offsets_are_relative_to_payload_header(self):
        obj = p.PE(image())
        previous = b'sbat,1,2023012900\nshim,2\ngrub,3\n\0'
        latest = b'sbat,1,2025051000\nshim,4\ngrub,5\n\0'
        body = struct.pack('<III', 0, 8, 8 + len(previous)) + previous + latest
        obj.sections['.sbatlevel'] = body
        self.assertEqual(obj.embedded_sbat_policies()[1]['grub'], 5)
        for end in range(len(body)):
            obj.sections['.sbatlevel'] = body[:end]
            with self.subTest(end=end), self.assertRaises(ValueError):
                obj.embedded_sbat_policies()

    def test_sbat_policy_ambiguity_and_out_of_range_rejected(self):
        for raw in (b'sbat,1\nsbat,1', b'sbat,1\ngrub,65536', b'sbat,2',
                    b'sbat,1,bad', b'sbat,1\ngrub,0', b'sbat,1\ngrub,5,time'):
            with self.subTest(raw=raw), self.assertRaises(ValueError):
                p.sbat_policy(raw)

    def test_certificate_tbs_is_exact_der_not_whole_certificate(self):
        cert = b'\x30\x0b\x30\x03abc\x30\x00\x03\x02\x00x'
        self.assertEqual(p.certificate_tbs(cert), b'\x30\x03abc')
        for end in range(len(cert)):
            with self.subTest(end=end), self.assertRaises(ValueError):
                p.certificate_tbs(cert[:end])

    def test_pkcs7_certificate_bag_without_signer_never_proves_signature(self):
        def der(tag, body): return bytes((tag, len(body))) + body
        cert = der(48, der(48, b'abc') + der(48, b'') + der(3, b'\0x'))
        signed = der(48, der(2, b'\1') + der(49, b'') + der(48, b'') +
                     der(160, cert) + der(49, b''))
        info = der(48, der(6, bytes.fromhex('2a864886f70d010702')) + der(160, signed))
        with self.assertRaisesRegex(ValueError, 'no signerInfo'):
            p.signature_certificates(info)
        for end in range(len(info)):
            with self.subTest(end=end), self.assertRaises(ValueError):
                p.signature_certificates(info[:end])

    def test_unknown_esl_type_is_retained_for_policy(self):
        kind = uuid.UUID('01234567-0123-0123-0123-0123456789ab')
        self.assertEqual(p.signature_lists(esl(kind, b'value')), [(kind, b'value')])


if __name__ == '__main__': unittest.main()
