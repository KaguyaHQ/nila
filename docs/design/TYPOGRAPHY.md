# Typography

The moonlight type system: one ramp, named by role. Every size, line-height,
and letter-spacing lives in the scale — markup names a role, never a pixel.
This is the authoritative reference; the tokens are defined in
[`assets/css/app.css`](../../assets/css/app.css) under the type-scale `@theme`
block, and the fonts are set alongside it.

## The two faces

| Face | Token | Stack | Used for |
| --- | --- | --- | --- |
| Display | `font-display` | **Newsreader** (editorial serif) | Hero, headings, and money figures. Sits at `font-normal` (400) — the serif reads contemplative when it isn't pushed bold. |
| Body | `font-sans` (default) | **DM Sans** | Everything else: reading copy, UI, labels. |

Both load via Google Fonts in `root.html.heex`. Display is the voice; sans is
the workhorse. Don't introduce a third face.

## The scale

Tailwind v4 generates a `text-{role}` utility from each step, with its
line-height and tracking **bundled in** — so `text-body` already carries its
`1.7` leading and `text-eyebrow` already carries its `0.2em` tracking. You
almost never write `leading-*` or `tracking-*` next to a type class.

### Display & headings — fluid, pair with `font-display`

Display steps use `clamp()`, so they scale smoothly with the viewport and need
**no responsive variants** (`sm:text-*`). Drop the breakpoint jumps; the clamp
handles it.

| Role | Class | Size (min → max) | Use |
| --- | --- | --- | --- |
| Hero | `text-hero` | 3.25 → 5.25rem | The one H1 per page. |
| Statement | `text-statement` | 3 → 4.5rem | Closing CTA, big editorial lines. |
| Heading 2 | `text-h2` | 2.25 → 3rem | Section headings. |
| Heading 3 | `text-h3` | 1.875 → 2.5rem | Sub-section / card-cluster headings. |
| Heading 4 | `text-h4` | 1.25rem (fixed) | Card titles, list-item headings. |

### Body & UI — fixed, sans

| Role | Class | Size | Use |
| --- | --- | --- | --- |
| Lead | `text-lead` | 17px | Hero sub, section intros. |
| Body | `text-body` | 15px | Default reading copy. |
| Small | `text-small` | 13px | Dense copy, list rows, mockup titles. |
| Fine | `text-fine` | 12px | Metadata, timestamps, table meta. |
| Micro | `text-micro` | 11px | Captions, footnotes, the smallest readable text. |

### Uppercase labels

| Role | Class | Size · tracking | Use |
| --- | --- | --- | --- |
| Eyebrow | `text-eyebrow` | 11px · 0.2em | Section kickers (`01 — The pipeline`). Pair with `.text-moon` for the sea-blue whisper. |
| Label | `text-label` | 11px · 0.14em | UI micro-labels inside product chrome (`/today`, status captions). |

Both expect `uppercase font-semibold` alongside; the token only owns size,
line-height, and tracking.

## Money & figures

Numerals are set in the **display serif** with `tabular-nums` so columns of
rupees align. Reuse a body step for the size and add `leading-none` for
single-line figures:

```heex
<p class="font-display text-lead leading-none tabular-nums">₹4,82,150.00</p>
```

`tabular-nums` and `leading-none` are the only line-height/tracking overrides
you should routinely pair with a type class — figures are the exception that
proves the rule.

## Rules

- **Name the role, not the pixel.** Never `text-[13.5px]`. If nothing fits,
  the scale is wrong — fix the scale, don't add a one-off.
- **No `leading-*` / `tracking-*` next to a type class.** It's already bundled.
  Exceptions: `leading-none` / `tabular-nums` on figures.
- **No `sm:text-*` on display roles.** The `clamp()` is the responsive behavior.
- **One face per job.** Serif for display and figures, sans for everything
  else. No third family, no swapping mid-page.
- **`font-normal` on the serif.** Display headings are 400, not bold — the
  weight comes from size, not ink.

## Migrating legacy markup

Older interior pages still carry arbitrary `text-[Npx]` with hand-tuned
`leading-*`/`tracking-*`. When you touch one of those screens, map each size to
its nearest step and delete the now-redundant leading/tracking — that's drift
to fix on contact, the same convention as the legacy-slate cleanup in
`DESIGN.md`. The landing page (`page_html/home.html.heex`) is the reference
implementation.

`mix nila.style_guard` fails the build on any raw size in `lib/nila_web`, so the
ramp stays the only way in. Default mappings (prefer intent when a site clearly
differs, and note it in the PR):

| Raw Tailwind | Role |
| --- | --- |
| `text-base` | `text-body` (paragraph); `text-h4` only if it's a real heading element |
| `text-sm` | `text-small` (dense UI: rows, cells, captions, helper, nav, buttons); `text-body` only for genuine reading copy |
| `text-xs` | `text-fine` (inline labels/hints/badges); `text-micro` for timestamps/metadata/footnotes |
| `text-lg` | `text-h4` (heading) or `text-lead` (intro copy) |
| `text-xl` | `text-h4` |
| `text-2xl` | `text-h4` (card/auth heading) or `text-h3` (page title) |
| `text-3xl` | `text-h3` |
| `text-4xl` | `text-h2` |
| `text-5xl` | `text-statement` (hero) or `text-h2` |
| `text-[10px]` / `text-[11px]` | `text-micro` |
| uppercase kicker + `tracking-[0.2em]` / `.text-moon` | `text-eyebrow` (drop the tracking) |
| uppercase micro-label + `tracking-[0.12–0.18em]` / `tracking-wide` | `text-label` (drop the tracking) |

A **compact title** authored at `text-sm`/`text-base` stays compact: its
`font-semibold` carries the heading, so don't promote it to `text-h4`. Only
`text-lg`/`xl`/`2xl`+ titles climb the display ramp. Money/KPI **figures** keep
their size bucket (a `text-4xl` figure becomes `text-h2`/`text-h3`, not
`text-h4`) and retain `tabular-nums`/`leading-none`.
