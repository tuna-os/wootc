#!/usr/bin/env python3
"""Package the pinned x86 Windows QEMU runtime without executing its installer.

The private manifest seed stays outside the archive. Every selected file,
including DLLs and helper images, is covered by the inner signed manifest.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "packaging/qemu-windows-source.json"
REQUIRED = ("qemu-system-x86_64.exe", "COPYING", "COPYING.LIB", "README.rst",
            "VERSION", "share/edk2-x86_64-code.fd", "share/edk2-i386-vars.fd",
            "share/edk2-licenses.txt", "share/bios-256k.bin", "share/vgabios-stdvga.bin")
SHARE_DIRS = {"doc", "icons", "keymaps", "locale", "man"}
SHARE_FILES = {"edk2-x86_64-code.fd", "edk2-x86_64-secure-code.fd", "edk2-i386-vars.fd",
               "edk2-licenses.txt", "bios.bin", "bios-256k.bin", "bios-microvm.bin",
               "kvmvapic.bin", "linuxboot_dma.bin", "multiboot_dma.bin", "pvh.bin",
               "qboot.rom", "trace-events-all"}


def digest(path, algorithm="sha256"):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, algorithm).hexdigest()


def selected_files(source):
    """Keep x86 system emulator, all DLLs, display data, docs and x86 firmware.

    Keeping all DLLs also retains dependencies loaded dynamically by display
    drivers. PE import-table traversal alone does not establish their absence.
    """
    for name in REQUIRED:
        if not (source / name).is_file():
            raise ValueError(f"QEMU runtime input missing: {name}")
    files = []
    for path in sorted(source.rglob("*")):
        if path.is_symlink():
            raise ValueError(f"runtime source contains a symlink: {path}")
        if not path.is_file():
            continue
        relative = path.relative_to(source)
        name = relative.as_posix()
        parts = relative.parts
        keep = name in REQUIRED
        if len(parts) == 1 and path.suffix.lower() == ".dll":
            keep = True
        if parts[0] == "share" and len(parts) > 1:
            keep |= parts[1] in SHARE_DIRS
            keep |= len(parts) == 2 and (parts[1] in SHARE_FILES or
                     parts[1].startswith(("vgabios", "efi-", "pxe-")))
            if len(parts) == 3 and parts[1] == "firmware":
                keep |= "x86_64" in parts[2] or "i386" in parts[2]
        if parts[0] == "lib":
            keep = True
        if keep:
            if any(char.isspace() for char in name) or "\\" in name or ":" in name:
                raise ValueError(f"unsupported manifest filename: {name}")
            files.append(relative)
    return files


def create_runtime(source, destination, helper, provenance):
    destination.mkdir(parents=True, exist_ok=False)
    for relative in selected_files(source):
        output = destination / relative
        output.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source / relative, output)
    for name in ("builder-vmlinuz", "builder-initramfs.img", "builder-protocol.json"):
        if not (helper / name).is_file() or (helper / name).stat().st_size == 0:
            raise ValueError(f"missing helper artifact: {name}")
        shutil.copyfile(helper / name, destination / name)
    protocol = json.loads((destination / "builder-protocol.json").read_text())
    if protocol.get("protocol") != "wootc-helper" or protocol.get("protocolVersion") != 1:
        raise ValueError("unsupported VM helper protocol")
    (destination / "runtime-source.json").write_text(json.dumps(provenance, indent=2) + "\n")
    lines = [f"{digest(path)}  {path.relative_to(destination).as_posix()}\n"
             for path in sorted(destination.rglob("*")) if path.is_file()]
    (destination / "SHA256SUMS").write_text("".join(lines))


def archive_runtime(source, output):
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for path in sorted(source.rglob("*")):
            if not path.is_file():
                continue
            name = "qemu/" + path.relative_to(source).as_posix()
            info = zipfile.ZipInfo(name, date_time=(2000, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            with path.open("rb") as incoming, archive.open(info, "w", force_zip64=True) as outgoing:
                shutil.copyfileobj(incoming, outgoing)


def build(installer, helper, seed, output, seven_zip):
    provenance = json.loads(SOURCE.read_text())
    with tempfile.TemporaryDirectory(prefix="wootc-vm-runtime-") as temp:
        work = Path(temp)
        if installer is None:
            installer = work / "qemu-setup.exe"
            with urllib.request.urlopen(provenance["url"], timeout=120) as response, installer.open("wb") as target:
                shutil.copyfileobj(response, target)
        if digest(installer, "sha512") != provenance["sha512"]:
            raise ValueError("QEMU installer does not match the pinned SHA-512")
        extracted = work / "extracted"
        subprocess.run([seven_zip, "x", "-y", f"-o{extracted}", str(installer)], check=True,
                       stdout=subprocess.DEVNULL)
        runtime = work / "qemu"
        create_runtime(extracted, runtime, helper, provenance)
        subprocess.run(["go", "run", "./tools/signmanifest", "sign", str(seed),
                        str(runtime / "SHA256SUMS"), str(runtime / "SHA256SUMS.sig")],
                       cwd=ROOT / "app", check=True)
        archive_runtime(runtime, output)
        print(json.dumps({"archive": str(output), "bytes": output.stat().st_size,
                          "sha256": digest(output), "runtime_bytes": sum(
                              p.stat().st_size for p in runtime.rglob("*") if p.is_file())}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--installer", type=Path, help="reuse a cached installer; SHA-512 is still mandatory")
    parser.add_argument("--helper-dir", required=True, type=Path)
    parser.add_argument("--signing-seed", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--seven-zip", default=shutil.which("7zz") or shutil.which("7z"))
    args = parser.parse_args()
    if not args.seven_zip:
        parser.error("7-Zip is required to extract the verified NSIS installer")
    try:
        build(args.installer.resolve() if args.installer else None, args.helper_dir.resolve(),
              args.signing_seed.resolve(), args.output.resolve(), args.seven_zip)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"VM runtime build failed: {error}\n")


if __name__ == "__main__":
    main()
