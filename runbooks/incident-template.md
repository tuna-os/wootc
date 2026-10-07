# Incident Template — wootc

Use this template to document and coordinate response to incidents affecting wootc users or deployments. Link to this issue from the applicable postmortem if an incident review is warranted.

## Incident information

- **Date/time started:** (UTC)
- **Date/time resolved:** (UTC)
- **Severity:** (SEV1 / SEV2 / SEV3 / SEV4)
- **Component(s):** (e.g., Windows installer, disk provisioning, Linux boot, migration, artifact verification)
- **Affected users/systems:** (number and Windows versions/hardware configurations involved)
- **Release(s) involved:** (version number or commit)

## Summary

<!-- One-paragraph summary of what happened. State the user-facing impact: installation failed, migration lost data, boot failed, migration helper didn't work, etc. Be specific about the stage (Windows setup, deployer, native boot, migration). -->

## Root cause

<!-- Measured cause, not a hypothesis. Reference specific logs, error messages, or traces. Windows-specific: include Event Viewer references or Windows logs if applicable. Linux side: include systemd/kernel logs. If not yet known, say so. Do not speculate. -->

## Timeline

<!-- Start from the earliest sign of the problem. Use UTC times. Include:
- When the problem first appeared (measured or first user report)
- When it was detected (CI failure, user report, monitoring)
- Key actions taken
- When the impact ended
- When the fix was applied (if different)

Format: HH:MM UTC — observed or action -->

## Impact

- **Duration:** (total time users were affected)
- **Scope:** (number of affected users, Windows versions, or hardware configurations)
- **What failed or changed:** (be specific: installer crash, disk image corruption, boot entry missing, migration helper failure, artifact verification failed, etc.)

## Resolution

<!-- What was done to stop the ongoing impact. If automated, describe the automation. If manual, describe the steps. Reference [rollback-a-bad-release.md](rollback-a-bad-release.md) if a rollback was used. -->

## Follow-up

- [ ] Postmortem scheduled (if SEV1/2, or if root cause analysis is incomplete)
- [ ] Tracking issue created: (link)
- [ ] Monitoring/alerting added to prevent recurrence
- [ ] Related issues or PRs filed
- [ ] CI updated to catch similar failures

## Notes

<!-- Anything else relevant: Windows version-specific behavior, hardware quirks, bootloader interactions, TPM/encryption issues, migration helper edge cases, etc. -->
