// @ts-check
// Bindings to the Go App struct. Kept by hand: regenerate with
// `wails generate module` when the wails CLI is available, and keep in
// sync with app.go's exported methods.

export function GetImages() {
  return window['go']['main']['App']['GetImages']();
}

export function GetSystemInfo() {
  return window['go']['main']['App']['GetSystemInfo']();
}

export function GetBranding() {
  return window['go']['main']['App']['GetBranding']();
}

export function StartInstall(arg1) {
  return window['go']['main']['App']['StartInstall'](arg1);
}

export function CancelInstall() {
  return window['go']['main']['App']['CancelInstall']();
}

export function GetStatus() {
  return window['go']['main']['App']['GetStatus']();
}

export function Reboot() {
  return window['go']['main']['App']['Reboot']();
}

export function ExistingInstallFound() {
  return window['go']['main']['App']['ExistingInstallFound']();
}

export function Uninstall() {
  return window['go']['main']['App']['Uninstall']();
}

export function CreateDataPartition(arg1) {
  return window['go']['main']['App']['CreateDataPartition'](arg1);
}

export function GetUninstallInfo() {
  return window['go']['main']['App']['GetUninstallInfo']();
}

export function UninstallWith(arg1) {
  return window['go']['main']['App']['UninstallWith'](arg1);
}

export function GetVMCapability() {
  return window['go']['main']['App']['GetVMCapability']();
}

export function BootInVM() {
  return window['go']['main']['App']['BootInVM']();
}

export function DefragDrive() {
  return window['go']['main']['App']['DefragDrive']();
}

export function GetMode() {
  return window['go']['main']['App']['GetMode']();
}

export function GetMigrationCategories() {
  return window['go']['main']['App']['GetMigrationCategories']();
}

export function ConvertCategory(arg1) {
  return window['go']['main']['App']['ConvertCategory'](arg1);
}

export function ImportBrowserData() {
  return window['go']['main']['App']['ImportBrowserData']();
}

export function GetAppMigrations() {
  return window['go']['main']['App']['GetAppMigrations']();
}

export function GetOfficeMigration() {
  return window['go']['main']['App']['GetOfficeMigration']();
}
