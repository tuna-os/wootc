// Package slurp is wootc's Windows data-migration knowledge: what a Windows
// user profile holds that is worth bringing to Linux, where it lives on the
// volume, and the shape of the look bundle wootc writes before it reboots.
//
// It needs only a path to a Windows volume (C:\ on a running Windows, or the
// volume bridged at /run/wootc/host on the installed Linux system): the
// user-folder categories (Categories, UserFolders, CategoryPath), profile
// discovery and selection (Profiles, ResolveProfile), the wallpaper source
// paths, the BCP-47 → XKB and Windows → IANA time zone maps, and the look
// bundle (Look, PinnedApp, BundleDir, LookFile, LookPath).
//
// The collectors that query a running Windows (netsh, the registry, DPAPI)
// stay in wootc's app; this module holds what both of wootc's sides share.
// It uses only the standard library.
package slurp
