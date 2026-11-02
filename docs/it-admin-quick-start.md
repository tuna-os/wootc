# IT administrator quick start: a supervised migration pilot

wootc is a consumer Windows-to-Linux installer, **not** a fleet deployment or
endpoint-management system. This guide organizes a supervised pilot on one
authorized, recoverable PC at a time. There is no implied unattended rollout,
domain migration, enterprise support agreement or zero-data-loss guarantee.
The [enterprise migration specification](specs/enterprise-migration.md) is a
proposal, not shipped fleet functionality.

Use [current status](status.md) to select the release and supported journey.
The [manual test guide](manual-testing.md) is for the legacy native path.
Its checklist does not prove a native WinUI or VM-first release.
If the selected build lacks matching instructions and evidence, stop the pilot.
Do not extend a mismatched procedure to multiple PCs.

## Before authorizing a pilot

- Name a change approver, operator, data owner and recovery contact. Get
  permission to change boot configuration, the ESP and any proposed partition
  layout. A local administrator password is not organizational approval.
- Use a spare/test PC before anyone's primary workstation. Record model,
  firmware, Windows edition/version, architecture, storage layout and the exact
  build/image. **Keep serial numbers and personal identifiers out of public logs.**
- Check UEFI, free space, power and Secure Boot requirements against the release.
  Do not generalize one vendor's successful boot to other firmware or images.
- Back up Windows, user data and WSL/application data to independent storage.
  Verify a restore. Prepare recovery media for Windows and an escalation route
  for boot repair. That route must not depend on the installed Linux system.
- Check BitLocker/device encryption and recovery-key escrow with the security
  owner. Confirm an authorized operator can retrieve the key if Windows requests
  it. Never put a key in a ticket, screenshot, script argument or public report.
  An alpha that refuses encrypted Windows is not permission to decrypt it.
  Experimental beta code for keys is not a release qualification; follow
  [the encryption policy](user-guide.md#7-encryption--bitlocker) and status gate.
- Confirm support for the user's hardware and required work in the Linux image.
  Check Office document fidelity/macros, accessibility, VPN, printers, smart cards,
  graphics, meetings, security tools and required applications. Neither a
  Linux alternative nor Wine/Proton implies compatibility with every workload.
- Save and close work. Arrange a maintenance window for more than the initial
  download. Include install, first login, Windows return, uninstall and recovery.

## Corporate networks and trust

Download only the pinned release asset and matching checksum manifest through
approved channels. Compare SHA-256 locally; a checksum does not authenticate a
publisher. The Windows binary may lack a signature; SmartScreen or application
control can refuse it. Do not disable Defender, SmartScreen, WDAC or company
policy to continue. Get a security decision first.

A blocked launch is valid pilot evidence.

Check outbound access from Windows to the selected release/artifact and image
registries. Separately check the network needed by the chosen deploy path.
A Wi-Fi-only deployment needs a build that supports preloaded payloads.
A preloaded OS image does not promise an entirely offline installation or updates.

Captive portals, TLS interception, authenticated proxies and custom CA requirements
need their own pilot. The privileged client for artifacts does **not** inherit
proxy settings from its environment. Do not bypass signature or TLS verification.
Stop and file the exact sanitized error if approved connectivity cannot work.
Never embed proxy passwords in an invitation or public log.

Saved home Wi-Fi is not proof of enterprise 802.1X enrollment. Expect to enroll
certificates and sign in through the organization's supported Linux procedure.
The migration does not automatically transfer Domain/Entra join, device compliance
or enterprise SSO to a new Linux account.

## Execute one complete journey

1. Pin the tag, Windows asset name/hash, image and approved storage plan in the
   local change record. Use the [download guide](getting-started.md) and the
   build's matching [user guide](user-guide.md). Do not invent silent-install
   flags or deploy to a group policy collection.
2. Capture a pre-change baseline for your change record: boot entries, owned
   ESP files, partition layout, encryption and power settings. Keep sensitive
   machine/account information in your own approved storage.
3. Review the app's proposed changes with the data owner. Installation can
   change boot files/settings; an alternate storage plan can change partitions.
   Stop on a different disk/partition or an unclear ownership warning.
4. Install, reach a real Linux desktop and test the required work task. Verify
   the contents of files, not only folder names. Cloud placeholders do not
   contain downloaded data. Migrate one category at a time; keep the source and
   backup. For developers, use [the WSL guide](wsl-migration.md).
5. Reboot into the Windows desktop. Check that original files and important
   applications still work. Re-enter Linux through the documented Manage path.
6. Follow the [uninstall verification protocol](manual-testing.md#proving-the-uninstall-put-everything-back).
   Capture its baseline **after installation and before uninstall**.
   Save it outside `C:\wootc`. Uninstall, boot Windows twice and run the verification.
   It supplements, not replaces, the pre-change baseline and recovery plan.

   From a reviewed checkout matching the test build, in Administrator PowerShell:

   ```powershell
   .\tests\field\verify-uninstall.ps1 capture -Out C:\uninstall-proof
   # Uninstall through Settings > Apps; boot Windows twice, then:
   .\tests\field\verify-uninstall.ps1 verify -Baseline C:\uninstall-proof -RootDisk keep
   ```

   The example preserves the Linux disk. Data deletion is a separate explicit
   choice. Export/verify Linux work before you request deletion. Keep the baseline
   and checklist in your change record, and sanitize any public attachment.
7. Record checkpoint outcomes, assistance, symptoms and sanitized evidence in a
   [field report](https://github.com/tuna-os/wootc/issues/new?template=manual-test-report.yml).
   Only expand after the approver reviews real recovery/uninstall evidence for
   each target hardware/image/storage cohort. One successful machine is not a
   fleet qualification.

## Rollback and escalation

- If Linux fails but firmware offers Windows Boot Manager, select it and verify
  the Windows desktop. A reboot request alone is not a successful return.
- If Windows runs, use the app's recovery/Manage controls described in
  [problems and recovery](user-guide.md#10-problems-and-recovery). An inspect
  operation is not a repair. Do not hand-edit BCD, delete ESP directories or
  remove another operating system's entries to force a green report.
- Uninstall tries to remove owned boot entries/files and restore the power
  settings it recorded; it can fail. It retains Linux data by default and does
  not undo migration onto a graduated native disk. Read every cleanup result.
  Verify Windows boot plus retained data before you declare rollback complete.
- If Windows will not start or recovery ownership is uncertain, stop. Use your
  organization's prepared process for Windows recovery and its recovery contact.
  Do not try an improvised partition resize or irreversible cleanup from chat.
- Stop rollout for suspected data loss, violations of security policy or failures
  of recovery. Preserve evidence and backups, and file a sanitized issue.
  Get a decision from the responsible maintainer/security owner.
  Complete a real rerun before you continue.

## Evidence and support boundaries

Internal operational records may contain sensitive details; public wootc reports
must not. Publish only sanitized results with consent. For an external alpha
cohort, use the [cohort aggregate gate](alpha-adopter-program.md), not a list of
employees or machines.

Do not advertise a migration Discussions category, response SLA or support channel
until a maintainer enables it and assigns moderation. Case studies from consultants
need actual outcomes and customer consent for publication.
This procedure is not a customer endorsement.
