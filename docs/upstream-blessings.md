# Upstream blessings

wootc ships one installer per distribution, and each one wears that
distribution's real mark, name, typeface and look
([branding-and-distribution.md §2](branding-and-distribution.md)). That is a
claim on somebody else's brand. This document is how the claim gets asked for
and how the answer gets recorded (#227).

The answers live in `app/branding/<brand>/blessing.json`, one record per
brand, summarised in the table in
[`app/branding/README.md`](../app/branding/README.md). They are not
documentation: `packaging/brands.sh` reads them, and a **declined** brand's
exe drops out of the release matrix.

**Recorded state as of 2026-11-02:** Bluefin, Bazzite and Aurora are all
`pending`, all four decisions are `pending`, `ask.filed` is `false`, and
`winget.identifierAgreed` is `false`. No third-party approval is recorded.
The self-owned `wootc` and `tunaos` records are `blessed`; that is not an
upstream endorsement of any image or migration path.

| Project | Authoritative permission record | Ask / branded distribution / winget |
| --- | --- | --- |
| Bluefin | [blessing.json](../app/branding/bluefin/blessing.json) | not filed / pending / not agreed |
| Bazzite | [blessing.json](../app/branding/bazzite/blessing.json) | not filed / pending / not agreed |
| Aurora | [blessing.json](../app/branding/aurora/blessing.json) | not filed / pending / not agreed |

The records, not assumptions in outreach issues, determine what is approved.
Asset provenance, shared organization membership, a successful build, previous
downloads or an unanswered invitation are not consent.

## Partner-ready release prerequisites

Issues [#594](https://github.com/tuna-os/wootc/issues/594),
[#592](https://github.com/tuna-os/wootc/issues/592) and
[#586](https://github.com/tuna-os/wootc/issues/586) share one review process.
A maintainer must own each request; no request is authorized or sent merely
because this document contains a draft.

Before presenting a branded download as approved or arranging co-promotion:

1. Name a wootc liaison and ask the project's authorized brand/release owner,
   through an existing permitted channel, whether they want a review. Verify the
   current venue with the project; historical URLs in `ask.venue` are not proof
   of permission to post there.
2. Supply a review packet tied to an exact release/commit: asset URL and
   checksums, actual filename, Windows signature/publisher status, asset licenses
   and provenance, UI screenshots from that build, image references/digests and
   the supported hardware/storage/channel matrix. Include real retained
   install → Linux login → Windows return → uninstall evidence and known
   migration/recovery gaps, not just a link to a moving latest run.
3. Ask the four branding questions separately. Ask the image maintainer to
   review catalog defaults, hardware fit, preload/update assumptions and the
   claimed file/Wi-Fi/profile migration behavior. Compatibility review is not
   implied by a logo permission.
4. Agree a review window with the reviewer. Two weeks is a proposal, not an
   imposed deadline or automatic approval. No reply leaves the record pending.
5. Record the authorized decision and durable public evidence for its exact
   scope. A private answer is not permission to publish its contents: obtain a
   publishable confirmation before entering it as public evidence. Record
   winget namespace/publisher agreement separately from permission to ship an exe.
6. Name the distributor, signing/release owner and support/escalation owner.
   Obtain any winget publishing credentials through the repository's secret
   settings, never in an issue or this document. A token is not brand permission.
7. Only then agree optional upstream docs PRs, download-page links, announcement
   copy, dates and aggregate metrics. Do not promise an upstream link or support
   commitment. Use consented real reports for case studies; download counts
   alone do not establish attempts or successful migrations.

**Enforcement gap:** `packaging/brands.sh` still includes pending brands by
default, warning in the log. Its existing `WOOTC_REQUIRE_BLESSING=1` mode drops
pending brands; release owners must use that mode for approval-gated public
distribution. This document does not claim that the default release workflow
already enforces prior approval. Declined brands are excluded in either mode.

For every later release, the liaison and release owner must compare the approved
identity, catalog and claims against the new build and retain new compatibility
evidence. Re-ask when scope or upstream requirements change; a previous yes is
not perpetual permission for new claims. The release owner records reviewed tag,
image digest, evidence and unresolved issues in the release evidence. Keep brand
permission, compatibility qualification and co-marketing approval distinct.

## What each project is asked

Four separate yes/no questions, because they can have different answers — a
project may be glad to be installed and still not want an exe carrying its
logo signed by someone else:

| Question | `blessing.json` key | What a "no" costs |
|---|---|---|
| May we ship your **mark** (logo, colours, typeface) inside the installer? | `decisions.mark` | the branded build loses its assets |
| May we call it **"`<Brand>` Installer"**? | `decisions.name` | the name reverts to generic wootc |
| May we use this **tagline**? | `decisions.tagline` | tagline reverts, brand can stay |
| May we **distribute an exe** under your brand at all? | `decisions.distributeExe` | the exe drops from every release |

Any single **no** makes the whole record `declined` — that is what
`derivedStatus` in `app/blessing_test.go` enforces, and it is deliberate: a
brand we may not name is not a brand we should ship.

## What to show them

Not a description — the actual thing:

1. **The branded walkthrough.** Their build's four screens, generated from
   their own assets: [branded-walkthroughs.md](branded-walkthroughs.md).
   Every image there is produced by `tests/gui/branded-walkthrough.spec.js`
   from `app/branding/<brand>/`, so it is what a user would really see.
2. **The provenance record.** Where each asset came from, in their own
   published branding: [`app/branding/README.md`](../app/branding/README.md)
   § Asset provenance. This answers "where did you get our logo" before it
   is asked.
3. **Retained E2E evidence** for the exact candidate build/image actually
   installing, migrating, returning to Windows and uninstalling. The
   [E2E index](https://tuna-os.github.io/wootc/e2e/latest/) is a discovery
   link, not by itself proof for the candidate.
4. **The rendered winget manifests** for their namespace (below) — an offer,
   not a submission.

## The winget namespace

`Bazzite.Installer` sits in Bazzite's publisher namespace, not ours. So the
identifier is *theirs*, and the offer is theirs to take up in whichever form
they want:

- **they publish** — we hand them the rendered manifests and the release
  asset URL, and they own the winget package outright;
- **we publish on their behalf** — only with an explicit yes recorded in
  `winget.identifierAgreed`, and they can take it over at any time;
- **no winget package** — the exe stays a direct download.

Only the generic `TunaOS.wootc` identifier is wired to the automatic submission
workflow (`.github/workflows/winget-publish.yml`); publishing still needs the
maintainer's credentials, first-submission review and a successful workflow.
No branded package may be submitted without its separate recorded namespace
agreement. See [`packaging/winget/README.md`](../packaging/winget/README.md).

Render a brand's manifests to show them exactly what would be published:

```sh
packaging/winget/render-brand.sh bazzite 0.2.0 \
  https://github.com/tuna-os/wootc/releases/download/v0.2.0/Bazzite-Installer.exe \
  <sha256> > /tmp/bazzite-manifests.txt
```

With no URL or hash it renders with placeholders, which is enough to show
the shape of the package.

## The request

Adapt per project; keep it short and make the "no" genuinely free.

> **Subject:** May we ship a Bazzite-branded Windows installer?
>
> We build [wootc](https://github.com/tuna-os/wootc), early software for
> installing a bootc Linux system beside Windows. It changes boot files and
> startup settings; some storage paths also change partitions. Windows return,
> migration and uninstall have limits documented in the attached evidence.
> We have built a variant whose window says "Bazzite Installer" and uses your
> mark, type and colours. Existing builds do not establish your approval.
>
> We would like your review before any further approved distribution or
> co-promotion. Four separate questions, and a no to any of them is
> completely fine:
>
> 1. May we use the Bazzite mark, colours and typeface in the installer?
> 2. May we call it "Bazzite Installer"?
> 3. May we use the tagline "`<the tagline from brand.json>`"?
> 4. May we distribute an exe branded as Bazzite at all?
>
> Here is the exact candidate and its checksums: `<pinned release links>`.
> Screenshots from that build: `<retained walkthrough link>`.
> Asset provenance and licenses: `<provenance link>`.
> Supported image references/digests, retained journey evidence and known
> limitations: `<candidate evidence links>`. Please also review image defaults
> and the migration claims; permission to use your mark will not be treated
> as a compatibility certification.
>
> On winget: `Bazzite.Installer` belongs in your namespace, not ours. We
> have the manifests rendered and would rather hand them to you than publish
> under a name that isn't ours — attached/below. We are not submitting
> anything until you say so.
>
> Would you like to review this, and is a two-week feedback window useful?
> No response will remain pending, not approved. Please identify the
> authorized reviewer and a public decision location we may cite.
>
> If the answer is no to any of it, tell us and we will drop it — the
> branded exe comes out of our release matrix, which is a one-line change on
> our side.

## Recording the answer

Edit `app/branding/<brand>/blessing.json`:

```jsonc
{
  "status": "blessed",              // falls out of the four answers
  "decisions": { "mark": "yes", "name": "yes",
                 "tagline": "yes", "distributeExe": "yes" },
  "winget": { "identifierAgreed": true },
  "ask": {
    "filed": true,
    "venue": "https://github.com/ublue-os/bazzite/issues",
    "shown": ["docs/branded-walkthroughs.md", "app/branding/README.md"],
    "openedAt": "2026-09-14",
    "decidedAt": "2026-09-21",
    "evidence": "https://github.com/ublue-os/bazzite/issues/1234#issuecomment-…"
  }
}
```

Then update the table row in `app/branding/README.md` to match — the tests
fail if it does not.

Rules the tests hold you to:

- **`status` is derived, never asserted.** Any `no` → `declined`; all four
  `yes` → `blessed`; anything else → `pending`.
- **A yes needs a link.** A brand this project does not own cannot be
  `blessed` without `ask.evidence`. A yes we cannot point at is a yes we
  invented.
- **So does a no.** `declined` needs evidence too: dropping someone's exe on
  a misremembered conversation is its own kind of wrong.
- **`selfOwned` is only `wootc` and `tunaos`.** It is the escape hatch from
  every check above, so it is pinned to the two marks this project actually
  owns.

## If a project declines

`packaging/brands.sh` stops listing that brand and the release matrix stops
building its exe — no other change is needed. Leave the directory and the
record in place: the record is the reason, and deleting it loses the memory
of having asked. Note the decision in `notes` and, if they asked for it,
remove the assets in a follow-up.
