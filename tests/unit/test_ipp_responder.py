#!/usr/bin/env python3
"""tests/e2e/ipp-everywhere-responder.py speaks enough IPP for CUPS.

The hosted E2E proves printer migration against this responder; if it stops
answering an operation CUPS uses, or drops an attribute `lpadmin -m
everywhere` needs, the E2E fails for a reason that has nothing to do with the
product. tests/migration/test-printers.sh drives it with a real CUPS; this
pins the wire behaviour without one.
"""
import http.client
import importlib.machinery
import importlib.util
from pathlib import Path
import struct
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parents[2]
RESPONDER = ROOT / "tests" / "e2e" / "ipp-everywhere-responder.py"


def load():
    loader = importlib.machinery.SourceFileLoader("ipp_responder", str(RESPONDER))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


R = load()

# What CUPS 2.4's ppdCreateFromIPP and ipp backend read from the printer.
REQUIRED = [
    "printer-uri-supported", "uri-security-supported", "uri-authentication-supported",
    "printer-make-and-model", "printer-state", "printer-state-reasons",
    "printer-is-accepting-jobs", "ipp-versions-supported", "operations-supported",
    "document-format-supported", "pwg-raster-document-resolution-supported",
    "pwg-raster-document-type-supported", "media-supported", "media-default",
    "media-ready", "media-col-database", "media-col-default", "sides-supported",
    "sides-default", "print-color-mode-supported", "print-color-mode-default",
    "printer-resolution-supported", "printer-resolution-default", "color-supported",
    "copies-supported", "charset-supported", "natural-language-configured",
]


def request(op, request_id, attrs=(), job_attrs=(), data=b""):
    groups = [(R.OPERATION_GROUP, [
        (R.CHARSET, "attributes-charset", ["utf-8"]),
        (R.LANGUAGE, "attributes-natural-language", ["en"]),
        (R.URI, "printer-uri", ["ipp://127.0.0.1/ipp/print"]),
        *attrs])]
    if job_attrs:
        groups.append((R.JOB_GROUP, list(job_attrs)))
    return R.encode((2, 0), op, request_id, groups) + data


class Responder(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.spool = tempfile.TemporaryDirectory()
        R.Handler.printer = R.Printer("127.0.0.1:0", cls.spool.name)
        cls.server = R.Server(("127.0.0.1", 0), R.Handler)
        cls.port = cls.server.server_address[1]
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.spool.cleanup()

    def post(self, body, chunked=False):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        headers = {"Content-Type": "application/ipp"}
        if chunked:
            # CUPS streams documents with chunked transfer encoding.
            def chunks():
                for i in range(0, len(body), 1000):
                    yield body[i:i + 1000]
            conn.request("POST", "/ipp/print", body=chunks(), headers=headers, encode_chunked=True)
        else:
            conn.request("POST", "/ipp/print", body=body, headers=headers)
        resp = conn.getresponse()
        self.assertEqual(resp.status, 200)
        self.assertEqual(resp.getheader("Content-Type"), "application/ipp")
        payload = resp.read()
        conn.close()
        version, status, request_id, attrs, _ = R.decode(payload)
        return status, request_id, attrs

    def test_get_printer_attributes_has_what_cups_needs(self):
        status, rid, attrs = self.post(request(0x000B, 7, [(R.KEYWORD, "requested-attributes", ["all", "media-col-database"])]))
        self.assertEqual((status, rid), (0, 7))
        missing = [a for a in REQUIRED if a not in attrs]
        self.assertEqual(missing, [])
        self.assertIn("application/pdf", attrs["document-format-supported"])
        self.assertIn("image/pwg-raster", attrs["document-format-supported"])
        for op in (0x0002, 0x0004, 0x0005, 0x0006, 0x0008, 0x0009, 0x000A, 0x000B):
            self.assertIn(op, attrs["operations-supported"])

    def test_print_job_spools_the_document(self):
        doc = b"%PDF-1.7 print-job " + b"x" * 5000
        status, _, attrs = self.post(request(0x0002, 2, [(R.MIME, "document-format", ["application/pdf"])], data=doc), chunked=True)
        self.assertEqual(status, 0)
        self.assertEqual(attrs["job-state"], [R.JOB_COMPLETED])
        job = attrs["job-id"][0]
        self.assertEqual((Path(self.spool.name) / f"job-{job}-1.pdf").read_bytes(), doc)

    def test_create_job_send_document_get_job(self):
        status, _, attrs = self.post(request(0x0005, 3, job_attrs=[(R.NAME, "job-name", ["os-release"])]))
        self.assertEqual(status, 0)
        job = attrs["job-id"][0]
        self.assertEqual(attrs["job-state"], [R.JOB_PENDING])
        doc = b"\x00RaS2" + b"r" * 3000
        status, _, attrs = self.post(request(0x0006, 4, [
            (R.INTEGER, "job-id", [job]), (R.BOOLEAN, "last-document", [True]),
            (R.MIME, "document-format", ["image/pwg-raster"])], data=doc), chunked=True)
        self.assertEqual(status, 0)
        self.assertEqual((Path(self.spool.name) / f"job-{job}-1.pwg").read_bytes(), doc)
        status, _, attrs = self.post(request(0x0009, 5, [(R.INTEGER, "job-id", [job])]))
        self.assertEqual((status, attrs["job-state"]), (0, [R.JOB_COMPLETED]))
        status, _, attrs = self.post(request(0x000A, 6, [(R.KEYWORD, "which-jobs", ["completed"])]))
        self.assertEqual(status, 0)
        self.assertIn(job, attrs["job-id"])

    def test_validate_and_cancel(self):
        self.assertEqual(self.post(request(0x0004, 8))[0], 0)
        _, _, attrs = self.post(request(0x0005, 9))
        job = attrs["job-id"][0]
        self.assertEqual(self.post(request(0x0008, 10, [(R.INTEGER, "job-id", [job])]))[0], 0)
        self.assertEqual(self.post(request(0x0008, 11, [(R.INTEGER, "job-id", [job])]))[0], R.NOT_POSSIBLE)
        self.assertEqual(self.post(request(0x0009, 12, [(R.INTEGER, "job-id", [999])]))[0], R.NOT_FOUND)

    def test_unknown_operation_is_refused(self):
        self.assertEqual(self.post(request(0x0010, 13))[0], R.OPERATION_NOT_SUPPORTED)

    def test_collections_round_trip(self):
        # media-col-database must decode as a collection CUPS can walk: a
        # malformed member would make ppdCreateFromIPP drop every page size.
        raw = R._attr(R.BEG_COLLECTION, "media-col-default", [R._media("a4", 21000, 29700)[1]])
        self.assertEqual(raw[0], R.BEG_COLLECTION)
        # media-size nested inside media-col: two well-formed end tags.
        self.assertEqual(raw.count(struct.pack(">bhh", R.END_COLLECTION, 0, 0)), 2)
        self.assertIn(struct.pack(">bhh", R.MEMBER_NAME, 0, len("x-dimension")) + b"x-dimension", raw)


if __name__ == "__main__":
    unittest.main()
