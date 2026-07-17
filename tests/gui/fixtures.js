// fixtures.js — mock data for each GUI scenario. Kept realistic so the
// screenshots double as documentation.

export const IMAGES = [
  { id: 'yellowfin-gnome', name: 'Yellowfin', emoji: '🐠', base: 'AlmaLinux Kitten 10', desktop: 'gnome', desktopName: 'GNOME', imageRef: 'ghcr.io/tuna-os/yellowfin:gnome', description: 'Modern GNOME desktop on Enterprise Linux. Stable and reliable.', bootloader: 'grub2', composeFs: false },
  { id: 'yellowfin-kde', name: 'Yellowfin', emoji: '🐠', base: 'AlmaLinux Kitten 10', desktop: 'kde', desktopName: 'KDE Plasma', imageRef: 'ghcr.io/tuna-os/yellowfin:kde', description: 'KDE Plasma desktop on Enterprise Linux.' },
  { id: 'bonito-gnome', name: 'Bonito', emoji: '🎣', base: 'Fedora 44', desktop: 'gnome', desktopName: 'GNOME', imageRef: 'ghcr.io/tuna-os/bonito:gnome', description: 'Cutting-edge GNOME on Fedora. Latest upstream packages.', bootloader: 'systemd-boot', composeFs: true },
  { id: 'marlin-gnome', name: 'Marlin', emoji: '🚀', base: 'Arch Linux', desktop: 'gnome', desktopName: 'GNOME', imageRef: 'ghcr.io/tuna-os/marlin:gnome', description: 'GNOME on Arch Linux with CachyOS kernel. For power users.', bootloader: 'systemd-boot', composeFs: true },
];

export const SYSINFO = {
  osVersion: 'Windows 11.0.22631', freeDiskGB: 214, totalDiskGB: 512,
  bitLockerOn: false, fastStartupOn: true, isUefi: true, secureBootOn: true, secureBootKnown: true,
};

export const INSTALL_STEPS = [
  { step: 'Checking system', message: 'Checking system…', percent: 2 },
  { step: 'Creating root.vhdx', message: 'Creating root.vhdx…', percent: 15 },
  { step: 'Downloading deployer', message: 'Downloading deployer kernel + initramfs… 60%', percent: 36 },
  { step: 'Setting up ESP', message: 'Setting up ESP…', percent: 65 },
  { step: 'Configuring BCD', message: 'Configuring BCD…', percent: 80 },
  { step: 'Collecting your look', message: 'Collecting your look…', percent: 90 },
];

export const MIGRATION_CATEGORIES = [
  { id: 'Documents', label: 'Documents', description: 'Your Windows Documents, already visible in your home folder.', sizeBytes: 13207470080, state: 'bridged', reversible: true },
  { id: 'Pictures', label: 'Pictures', description: 'Your Windows Pictures, already visible in your home folder.', sizeBytes: 8697308160, state: 'bridged', reversible: true },
  { id: 'Downloads', label: 'Downloads', description: 'Downloads now lives on Linux. The Windows copy is untouched.', sizeBytes: 2147483648, state: 'native', reversible: true },
  { id: 'steam', label: 'Steam games', description: 'Your Windows Steam library, playable in place — no re-download.', sizeBytes: 48426090496, state: 'bridged', reversible: true },
  { id: 'browser', label: 'Browser data', description: 'Bookmarks and history from Chrome/Edge, and your complete Firefox profile. Chrome and Edge passwords are locked by Windows and cannot move automatically.', sizeBytes: -1, state: 'available', reversible: true },
];

export const APPS = [
  { app: 'firefox', flatpak: 'org.mozilla.firefox', session: 'portable', copied: true, note: 'Everything moves: bookmarks, history, passwords, extensions, open tabs.' },
  { app: 'telegram', flatpak: 'org.telegram.desktop', session: 'portable', copied: true, note: 'Your session and chats moved — Telegram opens signed in.' },
  { app: 'vscode', flatpak: 'com.visualstudio.code', session: 'portable', copied: true, note: 'Settings, keybindings and snippets moved; extension list saved for reinstall.' },
  { app: 'discord', flatpak: 'com.discordapp.Discord', session: 'signin', copied: false, note: 'Your servers and messages live in your account — sign in once and everything is back.' },
  { app: 'spotify', flatpak: 'com.spotify.Client', session: 'signin', copied: false, note: 'Playlists and library are in your account — sign in once.' },
  { app: 'signal', flatpak: 'org.signal.Signal', session: 'none', copied: false, note: 'Re-link with your phone (Settings > Linked Devices); history stays on the phone.' },
];

export const OFFICE = {
  present: true,
  migrated: ['custom-dictionary', 'templates', 'fonts', 'office-format-defaults'],
  note: 'LibreOffice opens your Word/Excel/PowerPoint files directly and now saves in those formats by default. Fonts, templates and your custom dictionary came across; ribbon layout and macros do not transfer.',
};
