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

**Current state: nothing has been asked yet.** Bluefin, Bazzite and Aurora
are all `pending` with `ask.filed: false`. This document exists so that
filing the ask is a copy-paste rather than a blank page.

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
3. **A live E2E video** of that image actually installing, migrating and
   returning to Windows: <https://tuna-os.github.io/wootc/e2e/latest/>.
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

Only `TunaOS.wootc` is submitted automatically today
(`.github/workflows/winget-publish.yml`); no branded package is submitted
anywhere without a recorded yes. See
[`packaging/winget/README.md`](../packaging/winget/README.md).

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
> We build [wootc](https://github.com/tuna-os/wootc), an installer that puts
> a bootc image on a Windows machine from inside Windows — no USB, no
> repartitioning, and fully undoable. It already installs Bazzite, and we
> build a variant whose window says "Bazzite Installer" and wears your mark,
> type and colours, so users never see our project's name.
>
> We have not shipped that variant on your say-so and we are asking before
> it goes further. Four separate questions, and a no to any of them is
> completely fine:
>
> 1. May we use the Bazzite mark, colours and typeface in the installer?
> 2. May we call it "Bazzite Installer"?
> 3. May we use the tagline "`<the tagline from brand.json>`"?
> 4. May we distribute an exe branded as Bazzite at all?
>
> Here is exactly what it looks like today: `<branded walkthrough link>`.
> Every asset and where we took it from: `<provenance link>`. A real install,
> start to finish, on video: `<e2e link>`.
>
> On winget: `Bazzite.Installer` belongs in your namespace, not ours. We
> have the manifests rendered and would rather hand them to you than publish
> under a name that isn't ours — attached/below. We are not submitting
> anything until you say so.
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
