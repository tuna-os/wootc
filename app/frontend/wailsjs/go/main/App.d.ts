// Type declarations for the hand-kept App bindings (see App.js).

export interface Image {
  id: string;
  name: string;
  emoji: string;
  base: string;
  desktop: string;
  desktopName: string;
  imageRef: string;
  description: string;
}

export interface InstallConfig {
  imageRef: string;
  diskSizeGB: number;
  username: string;
  password: string;
  hostname: string;
  bootloader: string;
}

export interface InstallStatus {
  running: boolean;
  done: boolean;
  error?: string;
  existing: boolean;
}

export interface SystemInfo {
  osVersion: string;
  freeDiskGB: number;
  totalDiskGB: number;
  bitLockerOn: boolean;
  fastStartupOn: boolean;
  isUefi: boolean;
  secureBootOn: boolean;
}

export interface BridgeCategory {
  id: string;
  label: string;
  description: string;
  sizeBytes: number;
  state: 'bridged' | 'native' | 'available' | 'unavailable';
  reversible: boolean;
}

export function GetMode(): Promise<'installer' | 'migration'>;
export function GetMigrationCategories(): Promise<BridgeCategory[]>;
export function ConvertCategory(id: string): Promise<void>;
export function ImportBrowserData(): Promise<string>;
export function GetImages(): Promise<Image[]>;
export function GetSystemInfo(): Promise<SystemInfo>;
export function StartInstall(cfg: InstallConfig): Promise<void>;
export function CancelInstall(): Promise<void>;
export function GetStatus(): Promise<InstallStatus>;
export function Reboot(): Promise<void>;
export function ExistingInstallFound(): Promise<boolean>;
export function Uninstall(): Promise<void>;
