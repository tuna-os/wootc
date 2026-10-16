# Classic offline package prerequisites

This source checkpoint adds a package consumer for Debian and a policy renderer. It does not add the producer or launch a guest. The producer integration remains in draft #477 and source checkpoint `0ed8d7d`.

The plan binds 24 old and 20 new package archives to SHA256 values from signed Debian indexes. The original metadata record stays unchanged. Its host and package observations describe the earlier plan, not a completed guest installation. The large compressed indexes remain in the private directory for metadata.

The consumer freezes all archive files and checks their native control fields. Before any callback or installation, it reads the inventory from dpkg and needs a successful APT simulation to describe the complete approved transition. Each observed install must match the version and architecture. Removals must match the allowlist and original versions. Empty, partial, duplicate or malformed observations stop the operation before mutation. Installation uses local files with `--no-download` and no repository sources.

The controls use unsigned archives in the native format. Two simulations with APT cover both architectures, two upgrades and removal. They use private lists and status files. Both exit successfully and leave the status file unchanged. The recorded output includes the actual APT version and binary digest. These controls do not install packages or prove an OS boot.

The retained failure at `6148730` called the installer after an empty simulation. Checkpoint `2529d0f` repairs that gate. Checkpoint `50d394a` adds the actual APT observations. The original worktree and proofs remain intact.

Run the portable checks from the repository root:

```sh
python3 -m unittest discover -s tests/unit -p test_wootc_package_consumer.py
python3 tests/audit-classic-offline.py .
```

Execution still needs a qualified KVM host and pinned tool closure. The host must provide the required CPU, memory, scratch space and KVM interface that works. A pristine disk for Windows is also missing. It needs coherent TPM state, NVRAM and a UUID baseline. Its clone must pass fresh observations before use. 

Package and cloud acquisition, guest installation, Ubuntu/RPM dependency closure and firmware acceptance remain open. This checkpoint does not close #333.
