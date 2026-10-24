# ADR 0002: Hardware Pre-Flight & Hardware-Aware Image Matching (#38)

## Status
Superseded for driver matching by the live target-image inventory in #574.
The GREEN/AMBER/RED product policy remains historical context; image catalog
metadata is no longer treated as evidence that a specific kernel supports the
PC in front of the installer.

## Context
Issue #38 proposed hardware declarations in the image catalog. Issue #574
replaces that proxy with observations: after downloading the selected OCI image
while Windows still works, wootc reads its kernel module aliases and firmware
inventory, translates active Windows PnP IDs to Linux modaliases, and refuses
known-critical driver gaps before changing the boot configuration.

---

## 1. Classification & Color Model

Every hardware feature evaluation produces one of three honest verdicts:

| Color | Meaning | Behavior |
|---|---|---|
| **GREEN** | Full hardware compatibility covered by base image drivers. | Installation proceeds normally with default selection. |
| **AMBER** | Installation succeeds, but requires a documented post-install step or alternative connectivity (e.g. Broadcom Wi-Fi requiring wired Ethernet / phone USB tethering during setup). | Warning presented with explicit resolution steps; user can proceed. |
| **RED** | Hard incompatibility (e.g. x86-64-v1 CPU, Intel RST RAID active without AHCI mode, missing storage driver, 32-bit UEFI). | Hard stop with explanation; closest compatible variant suggested if available. |

---

## 2. Hardware Capability Catalog Metadata (superseded)

The original proposal declared constraints alongside image catalog metadata:

```json
{
  "id": "yellowfin-gnome",
  "cpu": { "level": "x86-64-v2" },
  "firmware": { "uefi": true, "secureBoot": true, "legacyBios": false, "uefi32": false },
  "storage": { "rstRaid": false, "nvme": true },
  "wifi": { "carries": ["iwlwifi", "ath11k"], "knownBadVendor": [] },
  "gpu": { "nvidia": false, "hybrid": false },
  "requires": { "packages": [], "layered": false },
  "supportTier": "green"
}
```

---

## 3. Historical decisions on open questions

These decisions describe the superseded catalog-driven design, not the live
kernel inventory gate:

1. **Broadcom Wi-Fi with Ethernet**: Classified as **AMBER**, never RED, as long as a secondary network path (wired Ethernet or USB phone tethering) exists.
2. **NVIDIA Variant Selection**: Offered as a explicit recommendation chip; never auto-swapped without user confirmation.
3. **Support Tiers**: Three tiers (`green`, `green-layered`, `experimental`) distinguish pre-built base images from dynamically layered driver packages.
4. **Telemetry**: Strict opt-in, default OFF, anonymized capability fingerprints only.
