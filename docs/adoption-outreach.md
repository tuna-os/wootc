# Adoption outreach: approval-gated material

This consolidates the overlapping content requests in #586, #590, #591, #592,
#594, #595 and #598 under [the external cohort gate](alpha-adopter-program.md)
and [the upstream review process](upstream-blessings.md). It is a set of drafts
and operating rules, **not** evidence that recruitment, partnerships, publication
or a successful migration has occurred. No outreach is authorized by this file.

Do not repeat issue-body claims that a tag or closed milestone proves a working
user journey. Check [current status](status.md) and retained evidence for the
exact release. Do not advertise “zero data loss”, “fully undoable”, identical
accounts, universal game compatibility, enterprise support or a completed
VM-first experience without the corresponding acceptance evidence.

## Channel strategy

The first five-person cohort uses the existing tunaOS Matrix community after
a maintainer names the room, intake owner and dates. Other channels below are
**candidates for a later, expressly approved campaign**, not places already
contacted or permission to broaden the cohort. Use existing warm relationships
and current community rules; moderators may decline. Do not send unsolicited
DMs, scrape membership, cross-post the same advertisement or treat help threads
as marketing opportunities.

| Candidate audience/channel | Value-first material | Permission and stop condition |
| --- | --- | --- |
| Existing tunaOS Matrix community | One small-cohort invitation with trust/recovery limits and reporting instructions | Maintainer approves launch and room/rules; pause at five accepted testers or any recovery/data-loss concern. |
| GitHub Discussions | A pointer to the approved invitation and a place for migration questions | Repository admin enables/chooses a category and assigns moderation first; do not advertise an unstaffed support SLA. |
| WSL community (for example r/bashonubuntu) | The WSL guide, explaining exactly what is and is not imported | Confirm subreddit spelling/current rules and moderator permission where required; answer a relevant question only when useful, with project affiliation disclosed. |
| Windows administrators/homelab (for example r/sysadmin or r/homelab) | A supervised pilot checklist and honest recovery boundaries | Obtain any required moderator approval; never present the consumer app as a fleet tool or cold-promote in unrelated questions. |
| Gaming, hardware-reuse or educational communities with an existing relationship | Workload compatibility checklist and a recoverable spare-PC trial | Community owner approves; no claim that old hardware, anti-cheat games or school devices are supported without evidence and device-owner permission. |

A campaign owner records the approved venue, date, exact published text/link and
aggregate responses in the cohort tracker. Do not retain contacts or handles in
public artifacts. Self-described WSL background is optional; count responses,
attempts and completions without tracking pixels, private demographics or
installation telemetry. Branded asset download counts may be reported in
aggregate but cannot be converted into people, attempts or successful journeys.

## Cohort invitation

**Draft, not sent.** The intake owner fills all factual details from the approved
tracker before publication; if anything below is unavailable, do not post.

> We are looking for five adult volunteers outside the wootc contributor team
> to try a supported Windows-to-Linux journey on a spare/recoverable PC. We
> especially welcome people who describe themselves as non-technical Linux
> users. Participation is optional; stopping or declining needs no explanation.
>
> This is early boot software, not a promise of a safe production migration.
> The Windows binary is currently unsigned and SmartScreen/policy may block it.
> Installation changes boot settings/files, and some storage plans change
> partitions. Windows return and uninstall can fail. Keep an independent,
> verified backup and recovery arrangements; never bypass organizational policy.
>
> The named intake owner will provide the exact approved tag, asset and checksum
> manifest, supported image/storage path, matching instructions, dates and contact
> from the cohort tracker. The journey is download → launch → Linux login →
> Windows return → Linux re-entry → uninstall/restoration → report. Stop if the
> documented steps do not match the screen or data/recovery looks wrong.
>
> Public GitHub reports expose your account; public participation is not
> anonymous. You may instead ask the intake owner to post a consented sanitized
> summary. Never share keys, account details or raw logs. Only aggregate cohort
> counts are published, and temporary participant records are removed at the
> gate decision. You can withdraw before publication; already-public copies
> cannot be promised erased.
>
> See the approved tracker for build links, dates and the intake owner, and the
> [program](https://github.com/tuna-os/wootc/blob/main/docs/alpha-adopter-program.md)
> for eligibility, evidence and privacy boundaries.

## WSL graduation article

**Publication draft for the tunaOS site, not a published blog post.** A site
editor must approve the final copy and replace moving links with the campaign's
reviewed instructions. The title deliberately avoids promising that all data or
accounts travel automatically.

### From WSL to native Linux: keep your starting point

If you already use Linux tools in WSL, a native Linux desktop may be a useful
next experiment. It is a separate system, not the same WSL installation booted
on bare metal. wootc installs a bootc Linux system beside Windows on supported
configurations, so you can test the workflow while keeping the original system.

Start with a recoverable PC and independent backups. Export each needed WSL
distribution, keep Windows/WSL installed, and check the release's current limits.
The helper can copy selected dotfiles and propose some development packages; it
does not import your entire distribution, projects, databases or sign-in state.
Review configuration for secrets and rebuild one real work task before deciding
whether the new setup fits.

The practical checklist is [Coming from WSL](wsl-migration.md). For the current
release's actual evidence, read [status](status.md). If you volunteer for an
approved alpha cohort, your report matters even when you stop at a trust prompt
or discover that the documentation does not fit. A verified Windows return and
uninstall are part of the experiment, not an afterthought. This is a trial of
real usability, not a claim that every WSL user can already graduate safely.

## Windows workflow and branded-distro pathways

These are planning choices, not endorsements or approved partner marketing.
Every third-party brand remains subject to its
[recorded permission and compatibility review](upstream-blessings.md).
Use the project's own hardware/application guidance as well as wootc's matrix.
A branded executable does not grant support for all its images.

| Audience | Possible pathway | Questions to resolve before migration |
| --- | --- | --- |
| Developer considering Bluefin | Follow the WSL export → supported image → selected config import → rebuild one project procedure in [the WSL guide](wsl-migration.md). | Is this exact Bluefin/Bluefin LTS/Dakota image admitted for the release and hardware? Are runtimes, container workflows, VPN and required credentials re-established? No whole-WSL/account transfer claim. |
| Gamer considering Bazzite | Check the exact hardware/image, back up saves, retain Windows and test one required game on Linux before relying on a library bridge. | Does that game's current anti-cheat/launcher/DRM permit Linux/Proton? Is the original library readable and supported by the bridge? Confirm saves and Windows return. No promise that every game works or that in-place reuse never requires downloading. |
| Productivity user considering Aurora | Choose a supported desktop/image, test real documents and peripherals, then compare the work task in both systems. | Do fonts, document formatting, macros, meetings, printers and accessibility work? The Office settings helper is not a Microsoft Office runtime, license transfer or complete conversion. |

**Office FAQ:** LibreOffice or OnlyOffice may suit a workflow, but compatibility
must be checked on copies of the user's actual documents. Keep originals and
Windows available; do not promise macro fidelity or automatic app-license transfer.

**Gaming FAQ:** Wine/Proton and access to library files do not make every Windows
game playable. Use current game/upstream guidance and report real outcomes.

**DevOps FAQ:** Reinstall tools through the destination distribution's supported
methods. A generated Brewfile is only a partial proposal, not environment parity.
Re-enroll secrets through approved processes; do not publish configurations or
customer code as evidence.

## Three case-study and walkthrough briefs

The following are **scenario briefs awaiting real volunteers**, not fabricated
case studies. They cover the developer, gamer and power-user asks in #586 and
the specialist story in #591. A real study/video needs consent, a named editor,
an exact tested build, actual results and separate approval to publish images,
quotes or identifying details. An unsuccessful trial is publishable only with
consent and accurate wording. Never stage a pass, invent a quote or promise a
walkthrough video before it has been recorded.

1. **Developer moving beyond WSL.** Record the initial distribution/workload
   privately, verify an export, install a supported image, show selected-dotfile
   limits, rebuild a non-sensitive project and compare outputs. Show Windows/WSL
   return, Linux re-entry and uninstall/restoration. Report assistance and missing
   packages or files, not just a successful shell prompt.
2. **Gamer evaluating Bazzite.** Check image/hardware and game compatibility,
   back up saves, show actual library discovery (or its absence), test one
   permitted game and verify saves on both systems. Record downloads still
   required. Finish Windows return and uninstall; do not characterize library
   visibility as playability.
3. **Power user or migration specialist evaluating Aurora.** Use the
   [administrator pilot](it-admin-quick-start.md) on an authorized spare machine.
   Open copies of representative documents, exercise one peripheral/network
   task, compare retained Windows data, and record return and uninstall checks.
   Do not generalize that result into a fleet or enterprise success story.

For each video, capture the actual build identity and download verification,
trust/UAC prompts, proposed storage plan, Linux task, Windows return, re-entry
and uninstall proof. Redact keys, names, notifications and customer data **before**
publication; do not run a camera over an unreviewed recovery-key screen. Link the
sanitized field report and underlying outcome so edited footage cannot hide a
failure. Retain the original evidence only through an approved storage/consent
process, not in git.

## Human decisions and ownership gaps

| Issues | Repository material | Required human action before acceptance |
| --- | --- | --- |
| #302, #598 | Cohort eligibility, intake, privacy, aggregate tracker and gate | Maintainer assigns intake/deputy, approves tag/channel and new dates, opens/links tracker, provides actual recruitment counts and qualifies the exact journey. The October #302 comment's dates were proposed, not approved. |
| #590 | Invitation and five-person/three-independent-completion rules | Authorized owner posts the approved invitation in Matrix and any enabled Discussion, recruits five consenting non-contributors (including two non-technical Linux users), triages actual reports within two working days, and records proceed/repeat/stop at #210. |
| #595 | WSL guide, article draft and optional aggregate WSL funnel | Documentation/site editors review and publish; community owner authorizes any warm-channel sharing. Real consenting WSL volunteers and evidence are required for success stories. |
| #591 | Administrator guide and supervised pilot/case-study brief | Repository admin chooses/enables a migration Discussion category and moderation; community owner approves any forum response/content; a real pilot with consent is required for a case study. |
| #594, #592 | Per-brand review packet and explicit approval procedure | Maintainer appoints liaison; authorized Bluefin/Bazzite/Aurora owners review branding and images and provide durable decisions; release owner enforces approval gating, signing/provenance and support ownership; upstream chooses whether to link or co-promote. |
| #586 | Channel plan, three workflow briefs, FAQs and partner process | Campaign editor obtains participant/publication consent and records real videos/results; upstream approves any branded messaging; maintainer supplies winget credentials and completes actual generic-package submission/review. Branded namespaces require separate permission, not merely a token. |

Publishing drafts, creating a tracker or adding a label is not external evidence.
No invitation, forum post, upstream request, Discussion-category change, site
publication, secret provisioning or winget submission was performed by adding
these repository artifacts.
