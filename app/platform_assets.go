package main

import "embed"

//go:embed grub/*.cfg
var platformAssets embed.FS

// catalogPolicyJSON owns wootc presentation, support status, and reviewed
// bootloader/MOK policy. Shared identities and backends come from the pinned
// upstream source embedded in catalog_sources.go, not data/images.json (the
// generated compatibility artifact used by packaging and E2E tooling).
//
//go:embed data/catalog-policy.json
var catalogPolicyJSON []byte
