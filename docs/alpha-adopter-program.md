# Alpha adopter program

**Status:** no evidence of recruitment; maintainer must decide whether to launch  
**Owner:** maintainer to assign before invitations  
**Issues:** [#302](https://github.com/tuna-os/wootc/issues/302),
[#590](https://github.com/tuna-os/wootc/issues/590),
[#598](https://github.com/tuna-os/wootc/issues/598)

As of 2026-11-02, the field-report template is present at
[manual-test-report.yml](../.github/ISSUE_TEMPLATE/manual-test-report.yml).
The assigned recruitment issues contain no participant counts or completed
external reports. That means **unknown**, not zero participants or a passed
gate. The October 11 comment on #302 proposed October 15–November 1 recruitment
and a November 15 decision; those were proposals, not approved dates.
Release tags, closed milestones and first-party runs do not satisfy this gate.

## Purpose

wootc's automated and first-party hardware tests answer whether the installer
works in controlled environments. The alpha adopter program answers a
different question: can a Windows user who did not build wootc complete the
journey, understand its trust boundaries, return to Windows, and report a
failure without private follow-up?

This is an evidence gate, not a growth campaign. Recruitment remains small
until recovery, uninstall, and reporting have been exercised by people outside
the project.

## Entry conditions

Recruitment starts only after all of the following are true:

- the structured field-report template in
  [#215](https://github.com/tuna-os/wootc/issues/215) is available;
- the current tagged alpha and its checksums are linked from the participant
  brief;
- the unsigned-binary and SmartScreen warning is shown before download;
- the manual-testing protocol includes Windows return and uninstall checks;
- one named maintainer owns intake and acknowledges new reports within two
  working days.
- the selected build's [status](status.md) and manual protocol match the UI and supported image/storage path.
  A legacy protocol does not qualify a native WinUI or VM-first journey;
- the owner opens an [aggregate cohort tracker](../.github/ISSUE_TEMPLATE/alpha-cohort.yml)
  and links it from #302 and #210.
  The owner enters the release, channel, dates for recruitment/reports, and owners for intake and deputy duties.
  The owner must explicitly approve the launch.

## Cohort and recruitment

Recruit five consenting testers who are not wootc contributors. Prefer a mix
of Windows 10 and 11, hardware vendors, Secure Boot states, and comfort levels.
At least two participants should describe themselves as non-technical Linux
users, matching the project's stated audience.

The first channel is the existing tunaOS Matrix community, after a maintainer
confirms the room and its rules. A GitHub Discussions notice may point to the
same invitation after approval; it is not a second uncontrolled cohort.
Do not send unsolicited direct messages or scrape members. Do not broaden
recruitment until the owner has triaged reports from the first five accepted testers.

### Eligibility and stopping rules

- Adults who explicitly volunteer and are not wootc contributors.
  A school or organization must give permission before its users take part.
- A spare or recoverable physical PC with Windows 10/11, x86-64 and UEFI.
  The participant must have permission to install software and change boot settings.
- A verified independent backup and a way to recover Windows.
  Access to any required recovery key, plus power and time for return/uninstall checks.
- Only the image, Secure Boot, encryption and storage combinations admitted
  by the chosen release's policy. Do not change encryption or company policy
  to qualify. Include different **supported** Secure Boot states when possible.
- Exclude a sole PC for important work/school use, managed devices without permission, and PCs without recovery arrangements.
  Exclude unsupported configurations for storage/encryption.

Participation is optional and may stop at any stage. A decline or withdrawal
needs no explanation. Stop for a documentation mismatch, unexpected partition
plan, missing data, blocked Windows return or uncertain recovery.

Preserve evidence, report it, and wait for the intake owner. Do not try commands
from chat. Suspected data loss or a recovery failure pauses new runs and
recruitment until the maintainer records a safe resolution.

### Common participant brief

In the approved invitation, the owner supplies the exact tag, asset URL,
checksum manifest and status link. The owner also supplies the
matching [user guide](user-guide.md), [manual protocol](manual-testing.md),
report-form link, report due date and intake contact.
Use the draft in [adoption outreach](adoption-outreach.md#cohort-invitation).
Never substitute a moving `latest` link for a pinned test build.

Explain before download: this is early Windows software without a signature.
SmartScreen or organizational policy can block it. Checksums do not identify a
publisher. Installation changes startup files and settings; some paths can
change partitions. Recovery and uninstall can fail.

There is no zero-data-loss guarantee. No one needs to weaken a security policy
or continue past a warning.

## Participant journey

Each tester receives the same short brief and follows the public documentation:

1. Download and verify the current tagged alpha.
2. Launch it and record any trust or SmartScreen blocker.
3. Attempt installation and first Linux login.
4. Reboot back into Windows.
5. Re-enter Linux using the documented management path.
6. Uninstall and verify that Windows boot behavior is restored.
7. Submit the structured report whether the journey passed or failed.

Testers must be told to stop rather than improvise when the documented path no
longer matches the screen. That mismatch is an adoption finding.

## Evidence ledger

The intake owner keeps one row locally for each participant who consents.
These temporary rows use random aliases, not account names or related identifiers.
Do not put those rows, contacts or maps from aliases to accounts in git or public issue comments.
Keep only the data needed to count each independent journey once:

| Field | Allowed values |
| --- | --- |
| Invitation channel | declared Matrix channel / approved referral |
| Invitation | accepted / declined / no response / withdrawn |
| Background, voluntary | WSL / new to Linux / other / not stated |
| Attempted journey | not started / download / launch / native install / VM-first (if qualified) |
| Download | reached / blocked / not attempted |
| Launch | reached / trust-blocked / other-blocked / not attempted |
| Linux first login | reached / not reached / not attempted |
| Windows return | verified / failed / not attempted |
| Linux re-entry | verified / failed / not attempted |
| Uninstall restoration | verified / failed / not attempted |
| Blocker | none / trust / preflight / storage / firmware-boot / network / migration-data / docs-usability / recovery-uninstall / other |
| Outcome | passed / product defect / docs defect / environment / abandoned |
| Follow-up | sanitized issue link or none |

An unattempted checkpoint is not a pass. A retry counts as one person, not a
second independent journey. If a maintainer intervenes, record the journey as
assisted. Do not present it as an independent completion.

Publish **aggregate counts only** in the tracker.
Count invitations, acceptance, declines, no response, withdrawals, tries,
downloads, launches and first logins. Also count Windows returns, Linux
re-entries, verified uninstalls, independent completions, assisted completions
and blockers by category.

Add separate links to sanitized reports. Do not link an individual report to
its private cohort alias. For #595, optionally count responses, tries and
completions by WSL background. Do not use pixels to track people or installer
telemetry. Omit small breakdowns by background/hardware that would identify a
participant.

Never request names, email addresses, serial numbers, passwords, recovery keys,
private keys or raw logs with account names. Public reports on GitHub are not
anonymous: explain this before the participant opts in. They may decline to
file a public report. With consent, the owner can file a sanitized summary instead.

Participants review every attachment. At the gate decision, delete temporary
participant rows and contact maps. Retain only aggregate counts and sanitized
reports with consent. For a withdrawal, remove unpublished rows and update
aggregates. Explain that the owner cannot promise that others will erase copies
of public GitHub data.

## Feedback ownership

The named intake owner (or named deputy) acknowledges reports within two
business days of submission. This is a launch prerequisite, not a service that
an unstaffed program already offers. For each report, record:

1. Checkpoint and blocker category, exact tested build, and whether the participant
   needed assistance or a retry.
2. Triage as green, fixed, or filed. For fixed, link the change and a real rerun.
   For filed, link the issue and name the responsible owner and next action.
   Do not mark filed as fixed.
3. For any data-loss/recovery concern, pause and escalate to the maintainer.
4. Link product/doc fixes back to the aggregate tracker.
   Get a new report before a failed journey can count as complete.

## Exit criteria

The external-adoption portion of the real-hardware gate is satisfied when:

- five external non-contributors have accepted an invitation.
  At least two describe themselves as non-technical users of Linux;
- at least three independently complete first login, Windows return, Linux
  re-entry, and uninstall restoration on the pinned supported journey;
- every unsuccessful journey has a blocker category and a linked issue when
  the cause is in wootc or its documentation;
- no unresolved data-loss or recovery blocker remains; and
- the maintainer records a proceed, repeat, or stop decision with the aggregate
  ledger linked from milestone
  [#210](https://github.com/tuna-os/wootc/issues/210).

These criteria complement the three first-party hardware runs in
[#216](https://github.com/tuna-os/wootc/issues/216); they do not replace them.

## Beta handoff

After the cohort, summarize the highest-frequency blocker, the largest funnel
drop, and any audience mismatch. Use those results to revise the Beta gate and
public adoption guidance before increasing recruitment or promising broad
Windows-user readiness.
