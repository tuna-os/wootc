#!/usr/bin/env python3
"""A minimal IPP Everywhere printer for the printer-migration proof.

    ipp-everywhere-responder.py --listen 127.0.0.2:631 --spool DIR

Standard library only, so it runs on any target image with python3. It speaks
IPP/2.0 over HTTP/1.1 at /ipp/print and answers what CUPS 2.4 needs to build
an IPP Everywhere queue (`lpadmin -m everywhere`, ppdCreateFromIPP) and to
print to it with the ipp backend:

    Get-Printer-Attributes, Validate-Job, Print-Job, Create-Job,
    Send-Document, Get-Job-Attributes, Get-Jobs, Cancel-Job

Every received document is written to the spool directory as
job-<id>-<n>.<ext> (atomically: a file there is complete), and each request
is logged on stdout as `IPP <operation> ...`, so the harness can assert both
that CUPS talked to the printer and that a document arrived.
"""

import argparse
import http.server
import itertools
import os
import socketserver
import struct
import sys
import tempfile
import threading
import time
import uuid

# Value tags (RFC 8010 §3.5).
UNSUPPORTED, NO_VALUE = 0x10, 0x13
INTEGER, BOOLEAN, ENUM = 0x21, 0x22, 0x23
OCTET, RESOLUTION, RANGE = 0x30, 0x32, 0x33
BEG_COLLECTION, END_COLLECTION, MEMBER_NAME = 0x34, 0x37, 0x4A
TEXT, NAME, KEYWORD, URI = 0x41, 0x42, 0x44, 0x45
CHARSET, LANGUAGE, MIME = 0x47, 0x48, 0x49
# Delimiter tags.
OPERATION_GROUP, JOB_GROUP, END_GROUP, PRINTER_GROUP = 0x01, 0x02, 0x03, 0x04

OPERATIONS = {
    0x0002: "Print-Job",
    0x0004: "Validate-Job",
    0x0005: "Create-Job",
    0x0006: "Send-Document",
    0x0008: "Cancel-Job",
    0x0009: "Get-Job-Attributes",
    0x000A: "Get-Jobs",
    0x000B: "Get-Printer-Attributes",
}
OK = 0x0000
BAD_REQUEST = 0x0400
NOT_FOUND = 0x0406
NOT_POSSIBLE = 0x0404
OPERATION_NOT_SUPPORTED = 0x0501

JOB_PENDING, JOB_PROCESSING, JOB_CANCELED, JOB_COMPLETED = 3, 5, 7, 9
EXTENSIONS = {
    "application/pdf": "pdf",
    "image/pwg-raster": "pwg",
    "image/jpeg": "jpg",
    "application/octet-stream": "bin",
}


# ── encoding ─────────────────────────────────────────────────────────────────

def _value(tag, v):
    if tag in (INTEGER, ENUM):
        return struct.pack(">i", v)
    if tag == BOOLEAN:
        return b"\x01" if v else b"\x00"
    if tag == RESOLUTION:
        x, y = v
        return struct.pack(">iib", x, y, 3)          # 3 = dots per inch
    if tag == RANGE:
        return struct.pack(">ii", *v)
    if isinstance(v, bytes):
        return v
    return str(v).encode("utf-8")


def _attr(tag, name, values):
    """One attribute; a list of member lists when tag is BEG_COLLECTION."""
    out = bytearray()
    for i, v in enumerate(values):
        n = name.encode() if i == 0 else b""
        if tag == BEG_COLLECTION:
            out += struct.pack(">bh", tag, len(n)) + n + struct.pack(">h", 0)
            for mtag, mname, mvalues in v:
                mn = mname.encode()
                out += struct.pack(">bhh", MEMBER_NAME, 0, len(mn)) + mn
                # A member's value is an attribute with an empty name.
                out += _attr(mtag, "", mvalues)
            out += struct.pack(">bhh", END_COLLECTION, 0, 0)
        else:
            data = _value(tag, v)
            out += struct.pack(">bh", tag, len(n)) + n + struct.pack(">h", len(data)) + data
    return bytes(out)


def encode(version, status, request_id, groups):
    out = bytearray(struct.pack(">bbhi", version[0], version[1], status, request_id))
    for group_tag, attrs in groups:
        out.append(group_tag)
        for tag, name, values in attrs:
            out += _attr(tag, name, values)
    out.append(END_GROUP)
    return bytes(out)


# ── decoding ─────────────────────────────────────────────────────────────────

def decode(body):
    """(version, operation, request-id, {name: [values]}, document data)."""
    if len(body) < 9:
        raise ValueError("short IPP message")
    major, minor, op, request_id = struct.unpack(">bbhi", body[:8])
    attrs, pos, name, depth = {}, 8, None, 0
    while pos < len(body):
        tag = body[pos]
        pos += 1
        if tag == END_GROUP:
            break
        if tag < 0x10:                                  # a new group
            continue
        nlen = struct.unpack(">h", body[pos:pos + 2])[0]
        n = body[pos + 2:pos + 2 + nlen].decode("utf-8", "replace")
        pos += 2 + nlen
        vlen = struct.unpack(">h", body[pos:pos + 2])[0]
        raw = body[pos + 2:pos + 2 + vlen]
        pos += 2 + vlen
        # Collection members are skipped: no request this printer handles
        # needs one (CUPS sends media-col on jobs; the printer accepts it).
        if tag == BEG_COLLECTION:
            depth += 1
            if depth == 1 and n:
                name = n
                attrs.setdefault(name, [])
            continue
        if tag == END_COLLECTION:
            depth -= 1
            continue
        if depth:
            continue
        if n:
            name = n
            attrs.setdefault(name, [])
        if name is None:
            continue
        if tag in (INTEGER, ENUM) and vlen == 4:
            attrs[name].append(struct.unpack(">i", raw)[0])
        elif tag == BOOLEAN and vlen == 1:
            attrs[name].append(raw != b"\x00")
        elif tag >= 0x40:
            attrs[name].append(raw.decode("utf-8", "replace"))
        else:
            attrs[name].append(raw)
    return (major, minor), op, request_id, attrs, body[pos:]


# ── the printer ──────────────────────────────────────────────────────────────

def _media(name, x, y):
    return name, [
        (BEG_COLLECTION, "media-size", [[
            (INTEGER, "x-dimension", [x]),
            (INTEGER, "y-dimension", [y]),
        ]]),
        (INTEGER, "media-bottom-margin", [423]),
        (INTEGER, "media-left-margin", [423]),
        (INTEGER, "media-right-margin", [423]),
        (INTEGER, "media-top-margin", [423]),
        (KEYWORD, "media-source", ["main"]),
        (KEYWORD, "media-type", ["stationery"]),
    ]


class Printer:
    def __init__(self, listen, spool):
        self.uri = f"ipp://{listen}/ipp/print"
        self.spool = spool
        self.uuid = f"urn:uuid:{uuid.uuid5(uuid.NAMESPACE_URL, self.uri)}"
        self.started = time.time()
        self.lock = threading.Lock()
        self.ids = itertools.count(1)
        self.jobs = {}

    def attributes(self):
        a4 = _media("iso_a4_210x297mm", 21000, 29700)
        letter = _media("na_letter_8.5x11in", 21590, 27940)
        sizes = [[(INTEGER, "x-dimension", [21000]), (INTEGER, "y-dimension", [29700])],
                 [(INTEGER, "x-dimension", [21590]), (INTEGER, "y-dimension", [27940])]]
        with self.lock:
            queued = sum(1 for j in self.jobs.values() if j["state"] < JOB_CANCELED)
        return [
            (URI, "printer-uri-supported", [self.uri]),
            (KEYWORD, "uri-security-supported", ["none"]),
            (KEYWORD, "uri-authentication-supported", ["none"]),
            (NAME, "printer-name", ["wootc-test-printer"]),
            (TEXT, "printer-info", ["wootc IPP Everywhere test printer"]),
            (TEXT, "printer-location", ["wootc E2E"]),
            (TEXT, "printer-make-and-model", ["wootc IPP Everywhere Responder"]),
            (TEXT, "printer-device-id", ["MFG:wootc;MDL:IPP Everywhere Responder;CMD:PDF,PWGRaster;"]),
            (URI, "printer-uuid", [self.uuid]),
            (URI, "printer-more-info", [f"http://{self.uri[6:].split('/')[0]}/"]),
            (ENUM, "printer-state", [3]),                              # idle
            (KEYWORD, "printer-state-reasons", ["none"]),
            (BOOLEAN, "printer-is-accepting-jobs", [True]),
            (INTEGER, "printer-up-time", [int(time.time() - self.started) + 1]),
            (INTEGER, "queued-job-count", [queued]),
            (KEYWORD, "ipp-versions-supported", ["1.1", "2.0"]),
            (KEYWORD, "ipp-features-supported", ["ipp-everywhere"]),
            (ENUM, "operations-supported", sorted(OPERATIONS)),
            (CHARSET, "charset-configured", ["utf-8"]),
            (CHARSET, "charset-supported", ["utf-8"]),
            (LANGUAGE, "natural-language-configured", ["en"]),
            (LANGUAGE, "generated-natural-language-supported", ["en"]),
            (MIME, "document-format-default", ["application/octet-stream"]),
            (MIME, "document-format-supported", list(EXTENSIONS)),
            (KEYWORD, "pdl-override-supported", ["attempted"]),
            (KEYWORD, "compression-supported", ["none"]),
            (BOOLEAN, "color-supported", [True]),
            (KEYWORD, "print-color-mode-supported", ["auto", "color", "monochrome"]),
            (KEYWORD, "print-color-mode-default", ["auto"]),
            (RESOLUTION, "pwg-raster-document-resolution-supported", [(300, 300), (600, 600)]),
            (KEYWORD, "pwg-raster-document-type-supported", ["black_8", "sgray_8", "srgb_8"]),
            (KEYWORD, "pwg-raster-document-sheet-back", ["normal"]),
            (RESOLUTION, "printer-resolution-supported", [(300, 300), (600, 600)]),
            (RESOLUTION, "printer-resolution-default", [(600, 600)]),
            (ENUM, "print-quality-supported", [3, 4, 5]),
            (ENUM, "print-quality-default", [4]),
            (KEYWORD, "media-supported", ["iso_a4_210x297mm", "na_letter_8.5x11in"]),
            (KEYWORD, "media-default", ["iso_a4_210x297mm"]),
            (KEYWORD, "media-ready", ["iso_a4_210x297mm", "na_letter_8.5x11in"]),
            (BEG_COLLECTION, "media-col-database", [a4[1], letter[1]]),
            (BEG_COLLECTION, "media-col-default", [a4[1]]),
            (BEG_COLLECTION, "media-col-ready", [a4[1], letter[1]]),
            (BEG_COLLECTION, "media-size-supported", sizes),
            (KEYWORD, "media-col-supported", ["media-size", "media-bottom-margin", "media-left-margin",
                                              "media-right-margin", "media-top-margin",
                                              "media-source", "media-type"]),
            (INTEGER, "media-bottom-margin-supported", [423]),
            (INTEGER, "media-left-margin-supported", [423]),
            (INTEGER, "media-right-margin-supported", [423]),
            (INTEGER, "media-top-margin-supported", [423]),
            (KEYWORD, "media-source-supported", ["main"]),
            (KEYWORD, "media-type-supported", ["stationery"]),
            (KEYWORD, "sides-supported", ["one-sided", "two-sided-long-edge", "two-sided-short-edge"]),
            (KEYWORD, "sides-default", ["one-sided"]),
            (KEYWORD, "output-bin-supported", ["face-down"]),
            (KEYWORD, "output-bin-default", ["face-down"]),
            (RANGE, "copies-supported", [(1, 99)]),
            (INTEGER, "copies-default", [1]),
            (ENUM, "finishings-supported", [3]),
            (ENUM, "finishings-default", [3]),
            (ENUM, "orientation-requested-supported", [3, 4, 5, 6]),
            (ENUM, "orientation-requested-default", [3]),
            (ENUM, "landscape-orientation-requested-preferred", [4]),
            (KEYWORD, "multiple-document-handling-supported",
             ["separate-documents-uncollated-copies", "separate-documents-collated-copies"]),
            (BOOLEAN, "multiple-document-jobs-supported", [False]),
            (INTEGER, "multiple-operation-time-out", [60]),
            (BOOLEAN, "job-ids-supported", [True]),
            (KEYWORD, "which-jobs-supported", ["completed", "not-completed"]),
            (KEYWORD, "printer-kind", ["document"]),
            (KEYWORD, "job-creation-attributes-supported",
             ["copies", "finishings", "media", "media-col", "orientation-requested",
              "output-bin", "print-color-mode", "print-quality", "printer-resolution", "sides"]),
        ]

    def job_attributes(self, job):
        reason = {JOB_COMPLETED: "job-completed-successfully",
                  JOB_CANCELED: "job-canceled-by-user"}.get(job["state"], "none")
        return [
            (INTEGER, "job-id", [job["id"]]),
            (URI, "job-uri", [f"{self.uri}/{job['id']}"]),
            (URI, "job-printer-uri", [self.uri]),
            (NAME, "job-name", [job["name"]]),
            (NAME, "job-originating-user-name", [job["user"]]),
            (ENUM, "job-state", [job["state"]]),
            (KEYWORD, "job-state-reasons", [reason]),
            (INTEGER, "job-impressions-completed", [1 if job["state"] == JOB_COMPLETED else 0]),
        ]

    def new_job(self, attrs):
        with self.lock:
            job = {"id": next(self.ids), "state": JOB_PENDING, "documents": 0,
                   "name": (attrs.get("job-name") or ["untitled"])[0],
                   "user": (attrs.get("requesting-user-name") or ["anonymous"])[0]}
            self.jobs[job["id"]] = job
        return job

    def store(self, job, attrs, data):
        fmt = (attrs.get("document-format") or ["application/octet-stream"])[0]
        with self.lock:
            job["documents"] += 1
            n = job["documents"]
        path = os.path.join(self.spool, f"job-{job['id']}-{n}.{EXTENSIONS.get(fmt, 'bin')}")
        fd, tmp = tempfile.mkstemp(prefix=".incoming-", dir=self.spool)
        with os.fdopen(fd, "wb") as f:
            f.write(data)
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
        log(f"IPP document job={job['id']} format={fmt} bytes={len(data)} file={path}")
        return path

    def handle(self, body):
        version, op, request_id, attrs, data = decode(body)
        name = OPERATIONS.get(op, f"0x{op:04x}")
        job_id = (attrs.get("job-id") or [None])[0]
        log(f"IPP {name} request-id={request_id} version={version[0]}.{version[1]}"
            + (f" job={job_id}" if job_id else ""))
        groups = [(OPERATION_GROUP, [
            (CHARSET, "attributes-charset", ["utf-8"]),
            (LANGUAGE, "attributes-natural-language", ["en"]),
        ])]
        status = OK
        if op == 0x000B:                                   # Get-Printer-Attributes
            groups.append((PRINTER_GROUP, self.attributes()))
        elif op == 0x0004:                                 # Validate-Job
            pass
        elif op in (0x0002, 0x0005):                       # Print-Job, Create-Job
            job = self.new_job(attrs)
            if op == 0x0002:
                self.store(job, attrs, data)
                job["state"] = JOB_COMPLETED
            groups.append((JOB_GROUP, self.job_attributes(job)))
        elif op in (0x0006, 0x0008, 0x0009):               # Send-Document, Cancel, Get-Job-Attrs
            job = self.jobs.get(job_id)
            if job is None:
                status = NOT_FOUND
            elif op == 0x0006:
                if job["state"] >= JOB_CANCELED:
                    status = NOT_POSSIBLE
                else:
                    self.store(job, attrs, data)
                    if (attrs.get("last-document") or [True])[0]:
                        job["state"] = JOB_COMPLETED
                    groups.append((JOB_GROUP, self.job_attributes(job)))
            elif op == 0x0008:
                if job["state"] >= JOB_CANCELED:
                    status = NOT_POSSIBLE
                else:
                    job["state"] = JOB_CANCELED
            else:
                groups.append((JOB_GROUP, self.job_attributes(job)))
        elif op == 0x000A:                                 # Get-Jobs
            which = (attrs.get("which-jobs") or ["not-completed"])[0]
            with self.lock:
                jobs = list(self.jobs.values())
            for job in jobs:
                done = job["state"] >= JOB_CANCELED
                if (which == "completed") == done:
                    groups.append((JOB_GROUP, self.job_attributes(job)))
        else:
            status = OPERATION_NOT_SUPPORTED
        return encode(version, status, request_id, groups)


def log(line):
    print(line, flush=True)


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    printer = None

    def log_message(self, fmt, *args):
        pass

    def _body(self):
        if "chunked" in self.headers.get("Transfer-Encoding", "").lower():
            out = bytearray()
            while True:
                size = int(self.rfile.readline().split(b";")[0].strip() or b"0", 16)
                if size == 0:
                    while self.rfile.readline() not in (b"\r\n", b"\n", b""):
                        pass
                    return bytes(out)
                out += self.rfile.read(size)
                self.rfile.readline()
        return self.rfile.read(int(self.headers.get("Content-Length") or 0))

    def _reply(self, code, ctype, payload):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_POST(self):
        body = self._body()
        if self.headers.get("Content-Type", "").split(";")[0].strip() != "application/ipp":
            self._reply(400, "text/plain", b"application/ipp only\n")
            return
        try:
            payload = self.printer.handle(body)
        except (ValueError, struct.error) as e:
            log(f"IPP malformed request: {e}")
            payload = encode((2, 0), BAD_REQUEST, 0, [(OPERATION_GROUP, [
                (CHARSET, "attributes-charset", ["utf-8"]),
                (LANGUAGE, "attributes-natural-language", ["en"])])])
        self._reply(200, "application/ipp", payload)

    def do_GET(self):
        self._reply(200, "text/plain", b"wootc IPP Everywhere responder\n")


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--listen", default="127.0.0.2:631", help="host:port (default 127.0.0.2:631)")
    ap.add_argument("--spool", required=True, help="directory received documents are written to")
    args = ap.parse_args(argv[1:])
    host, _, port = args.listen.rpartition(":")
    os.makedirs(args.spool, exist_ok=True)
    Handler.printer = Printer(args.listen, args.spool)
    server = Server((host, int(port)), Handler)
    log(f"IPP listening on {Handler.printer.uri} spool={args.spool}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
