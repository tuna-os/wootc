package main

import "embed"

//go:embed grub/*.cfg
var platformAssets embed.FS
