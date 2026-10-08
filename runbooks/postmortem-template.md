# Postmortem Template — wootc

Use this template to conduct a structured review of incidents affecting wootc. The goal is to understand what happened, why, and how to prevent recurrence. Postmortems are blameless: they focus on systemic factors and process, not individual actions.

Reference the related incident issue for details on timeline, impact, and resolution.

## Postmortem information

- **Incident issue:** (link)
- **Date conducted:** (UTC)
- **Attendees:** (list of participants)
- **Facilitator:** (who led the review)
- **Postmortem lead:** (primary author)

## Incident summary

<!-- One paragraph. Link to the incident issue for full details. State what happened and the user-facing impact. -->

## Root cause analysis

### Primary cause

<!-- What was the direct technical cause? Be specific and evidence-based. For hybrid Windows/Linux scenarios, distinguish between Windows-side failure, Linux-side failure, and integration failures. -->

### Contributing factors

<!-- Systemic or process factors that enabled or worsened the incident. Examples:
- Testing gap (Windows version not tested, hardware configuration not covered, edge case uncovered)
- CI gap (E2E check missing, artifact verification not comprehensive, rollback scenario not tested)
- Integration gap (bootloader assumptions, TPM/encryption interaction, migration data format compatibility)
- Documentation gap (user expectations misaligned, recovery procedure unclear)
- Release gap (artifact signing broken, manifest mismatch, distribution channel issue)
- Migration helper gap (data loss, incompatibility with source/target systems)
-->

## Timeline

<!-- Detailed timeline from incident issue, with added context on decisions and their rationale. -->

## Impact review

- **Duration:** (how long users were affected)
- **Scope:** (number of affected users, Windows versions, or hardware configurations)
- **Detectability:** (how was it discovered, could it have been detected sooner in CI or through monitoring)

## Lessons learned

### What went well

<!-- Actions or safeguards that contained or mitigated the incident. -->

### What could be improved

<!-- Process, tooling, testing, CI, documentation, or deployment changes that would prevent or reduce the impact of a similar incident. -->

## Action items

<!-- Specific, measurable steps to address root causes and contributing factors. Each item should:
- State the problem being solved
- Propose a specific solution
- Assign an owner (or "unassigned")
- Estimate effort (small / medium / large)
- Set a target date for completion

Example:
- [small, 2026-11-01] Add Windows 11 22H2 E2E test to CI matrix. (tuna-os/wootc#NNN)
- [medium, 2026-11-15] Add TPM/BitLocker interaction test for disk provisioning. (tuna-os/wootc#NNN)
-->

## Sign-off

- **Reviewed by:** (stakeholder, maintainer, or operations)
- **Date:** (UTC)

## Related resources

- [Incident template](incident-template.md)
- [Rollback procedure](rollback-a-bad-release.md)
- Related issue(s): (links)
- Architecture boundary: docs/architecture-boundary.md
