# ADR 0002: Hardware Pre-Flight & Hardware-Aware Image Matching (#38)

## Status
Approved RFC / Architecture Specification

## Context
Issue #38 defines the hardware pre-flight classification and image matching specification for **wootc**.
Before touching any disk or modifying bootloader configurations, wootc performs an honest hardware capability assessment against candidate `bootc` container images, ensuring users are never left with an unbootable or network-less system.

---

## 1. Classification & Color Model

Every hardware feature evaluation produces one of three honest verdicts:

| Color | Meaning | Behavior |
|---|---|---|
| **GREEN** | Full hardware compatibility covered by base image drivers. | Installation proceeds normally with default selection. |
| **AMBER** | Installation succeeds, but requires a documented post-install step or alternative connectivity (e.g. Broadcom Wi-Fi requiring wired Ethernet / phone USB tethering during setup). | Warning presented with explicit resolution steps; user can proceed. |
| **RED** | Hard incompatibility (e.g. x86-64-v1 CPU, Intel RST RAID active without AHCI mode, missing storage driver, 32-bit UEFI). | Hard stop with explanation; closest compatible variant suggested if available. |

---

## 2. Hardware Capability Catalog Metadata

Hardware constraints and driver capabilities are declared alongside image catalog metadata in `app/data/images.json`:

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

## 3. Decisions on Open Questions

1. **Broadcom Wi-Fi with Ethernet**: Classified as **AMBER**, never RED, as long as a secondary network path (wired Ethernet or USB phone tethering) exists.
2. **NVIDIA Variant Selection**: Offered as a explicit recommendation chip; never auto-swapped without user confirmation.
3. **Support Tiers**: Three tiers (`green`, `green-layered`, `experimental`) distinguish pre-built base images from dynamically layered driver packages.
4. **Telemetry**: Strict opt-in, default OFF, anonymized capability fingerprints only.
