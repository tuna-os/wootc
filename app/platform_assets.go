package main

import "embed"

//go:embed grub/*.cfg
var platformAssets embed.FS

// catalogJSON is the built-in image catalog. C:\wootc\images.json overrides it
// at runtime for custom/enterprise deployments (see GetImages).
//
//go:embed data/images.json
var catalogJSON []byte
