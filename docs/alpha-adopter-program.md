# Alpha adopter program

**Status:** proposed for `v0.2.0-alpha`  
**Owner:** maintainer to assign  
**Tracking:** [#302](https://github.com/tuna-os/wootc/issues/302)

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

## Cohort and recruitment

Recruit five consenting testers who are not wootc contributors. Prefer a mix
of Windows 10 and 11, hardware vendors, Secure Boot states, and comfort levels.
At least two participants should describe themselves as non-technical Linux
users, matching the project's stated audience.

Use one declared recruitment channel first (for example the tunaOS Matrix
room). Record only the channel and invitation count; do not publish participant
identities. Do not broaden recruitment until the first five reports have been
triaged.

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

Maintain an issue comment or milestone table with one anonymous row per
participant:

| Field | Allowed values |
| --- | --- |
| Invitation | accepted / declined / no response |
| Download | reached / blocked |
| Launch | reached / trust-blocked / other-blocked |
| Linux first login | reached / not reached |
| Windows return | verified / failed / not attempted |
| Uninstall restoration | verified / failed / not attempted |
| Outcome | passed / product defect / docs defect / environment / abandoned |
| Follow-up | linked issue or none |

Publish aggregate counts only. Do not collect names, email addresses, recovery
keys, machine serial numbers, logs containing account names, or telemetry from
the installed system. Participants choose what to attach to their report after
reviewing it.

## Exit criteria

The external-adoption portion of the real-hardware gate is satisfied when:

- five external testers have accepted an invitation;
- at least three independently complete first login, Windows return, and
  uninstall restoration;
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
