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
  bootloader: 'grub2' | 'systemd-boot';
  composeFs: boolean;
  family: string;
}

export interface InstallConfig {
  imageRef: string;
  diskSizeGB: number;
  username: string;
  password: string;
  hostname: string;
  bootloader: 'auto' | 'grub2' | 'systemd-boot';
  composeFs: boolean;
  storageDrive: string;
  encryption: 'none' | 'tpm2-luks' | 'luks-passphrase';
  luksPassphrase: string;
  windowsLook?: boolean;
  sessionConsent?: Record<string, boolean>;
}

export interface SessionCandidate {
  app: string;
  kind: 'chromium' | 'plainfile';
  portable: boolean;
  recommend: 'copy' | 'relink' | 'signin';
  note: string;
  consentRequired: boolean;
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
  bitLockerState: 'off' | 'on' | 'encrypting' | 'decrypting';
  fastStartupOn: boolean;
  isUefi: boolean;
  secureBootOn: boolean;
  secureBootKnown: boolean;
  defragRecommended: boolean;
  dataPartitions: Array<{letter: string; label: string; freeGB: number; encrypted: boolean}>;
  /** Windows computer name sanitised into a legal Linux hostname (#174).
   *  Empty when unreadable or when nothing usable survives sanitisation. */
  suggestedHostname: string;
  /** Windows account name sanitised into a legal Linux username (#174).
   *  Empty when unreadable or when nothing usable survives sanitisation. */
  suggestedUsername: string;
}

export interface BridgeCategory {
  id: string;
  label: string;
  description: string;
  sizeBytes: number;
  state: 'bridged' | 'native' | 'available' | 'unavailable';
  reversible: boolean;
}

export interface AppMigration {
  app: string;
  flatpak: string;
  session: 'portable' | 'signin' | 'relink' | 'none';
  copied: boolean;
  note: string;
  consentAvailable: boolean;
  consent: boolean;
}

export interface MigrationProfile {
  linuxUser: string;
  windowsProfile: string;
  matched: boolean;
  note: string;
}

export interface LookMigration {
  available: boolean;
  applied: boolean;
  items: string[];
  note: string;
}

export function GetMode(): Promise<'installer' | 'migration'>;
export function GetMigrationCategories(): Promise<BridgeCategory[]>;
export function ConvertCategory(id: string): Promise<void>;
export function ImportBrowserData(): Promise<string>;
export function GetSessionCandidates(): Promise<SessionCandidate[]>;
export function GetAppMigrations(): Promise<AppMigration[]>;
export function GetOfficeMigration(): Promise<any>;
export function SetSessionConsent(app: string, consent: boolean): Promise<void>;
export function ReinstallApps(): Promise<void>;
export function GetMigrationProfile(): Promise<MigrationProfile>;
export function SetMigrationProfile(profile: string): Promise<void>;
export function GetLookMigration(): Promise<LookMigration>;
export function GetImages(): Promise<Image[]>;
export function GetSystemInfo(): Promise<SystemInfo>;
export function StartInstall(cfg: InstallConfig): Promise<void>;
export function CancelInstall(): Promise<void>;
export function GetStatus(): Promise<InstallStatus>;
export function Reboot(): Promise<void>;
export function ExistingInstallFound(): Promise<boolean>;
export function Uninstall(): Promise<void>;
export function DefragDrive(): Promise<void>;
export function GetVMCapability(): Promise<any>;
export function BootInVM(): Promise<void>;
export function GetFreshVMCapability(): Promise<any>;
export function TryInVMFresh(imageRef: string): Promise<void>;
export function InstallPreviewForReal(cfg: InstallConfig): Promise<void>;

export function E2EDriveDirective():Promise<string>;

export function E2EDriveReport(arg1:string):Promise<void>;

export function GetSupportPolicy():Promise<Record<string, any>>;
export function GetLastRun():Promise<Record<string, any>>;
export function BootIntoLinux():Promise<void>;
export function GetRecoveryVerdict():Promise<Record<string, any>>;
export function TryAgain():Promise<void>;
export function RepairBoot():Promise<void>;
