# DESIGN.md — Nila

The single design reference: brand, product principles, and the **moonlight**
visual system. Read this before editing `.heex` or components. It complements
`AGENTS.md` (Elixir/Phoenix rules). Layout architecture (shell, cockpits) lives
in [`layout.md`](./layout.md).

## Brand

**Nila** (நிலா) — the moon. Cyclical, calm, reliable, quiet. It works while you
sleep; it's reflective, not generative — it processes and softens what's already
there and surfaces only what needs a human. That is literally the product: an
AI accountant that drafts the compliance back office's work in the background.
The brand should feel like the moon, not the sun.

Traits → design: **calm/graceful** → muted low-glare palette, ink and whitespace
carry the page; **quiet** → restraint — few sizes, few weights, 1px borders,
soft shadows, the data leads; **reflective** → soft luminance over hard
contrast; **reliable** → consistency, the same tokens and patterns everywhere.

Voice: plain, precise, unhurried. No exclamation marks, no "supercharge /
blazing-fast." The readers are CAs and their staff — professionals, not leads to
convert. Confident understatement; let the calm do the work.

## Principles

Nila drafts, the human reviews, the CA signs. Every screen answers to that loop.

- **Lead with what needs the human.** The first thing on any screen is the
  exception pile — what's waiting for review and what's blocking the close. Not
  a feed, not a score, not a re-pitch of the product.
- **Arrive with the work done.** Records come pre-filled from the documents
  that created them. Screens exist for reviewing and correcting, never
  transcribing. The default state of a record is already populated.
- **Propose, then confirm — and a guess never looks like a fact.** Calibration
  is the product. Every drafted line shows what it matched on and how sure it
  is; nothing commits business state without a human tap on the uncertain ones.
- **Prevent the error at creation.** A misclassified line or a wrong tax split
  should be caught in the review pane, not discovered in a filed return.
- **Nothing is filler; remove before adding.** Show the number that matters,
  defer the rest. When a screen feels unclear, subtract first. Grouping and
  hierarchy should explain the screen, not instructional copy.
- **Visual weight matches consequence.** A draft looks like a draft;
  an irreversible action looks like a last resort, never an equal option next
  to a safe one.
- **Match density to the moment.** Queue lists are tight and glanceable — a row
  understood at once. Review surfaces breathe, because that's where a human
  makes a signing decision.
- **Speak the operator's language.** Labels are words they'd say out loud, not
  software jargon. Numbers are the product: tabular figures aligned down the
  column, Indian digit grouping always (₹12,50,000).
- **Calm is the aesthetic.** Their world is overload; relief is the deliverable.
  Beauty is how we win the tie, never the reason we win.

## The ledger (marketing pages only)

The public homepage is set as a leaf from an account book: warm paper
(`bg-paper`), true ink (`text-ink`), feint blue ruling (`border-feint`), the
double red margin rule (`redink`), and double rules opening/closing the leaf.
Those four tokens live in `app.css` under "Ledger (marketing identity)" and are
for marketing surfaces only — product screens stay on moonlight below. Red ink
means exactly one thing there: a line waiting on a human.

## The moonlight system

The feeling is moonlight on a pale wall: calm, quiet, reflective — soft
luminance, never glare. Cool near-white surfaces, a deep midnight-sea "ink", a
hushed sea-blue primary warmed by a single sand accent, soft layered shadows,
and an editorial serif over a light sans. No purple.

### Stack

- **Tailwind v4** (no `tailwind.config.js`) — tokens live in `assets/css/app.css`.
- **daisyUI v5** — single light theme defined in `app.css`. Components inherit it.
- **HEEx / Phoenix LiveView 1.1** — markup in `lib/nila_web`.

There is **no dark mode** — light only.

### Color

Defined as the daisyUI `light` theme in `assets/css/app.css`. Use semantic
daisyUI/Tailwind tokens (`primary`, `base-content`, `base-300`…) in markup —
never hard-code hex.

| Token | Value | Role |
| --- | --- | --- |
| `primary` | sea blue `#316177` → `oklch(47% 0.06 232)` | Primary actions, links, accents |
| `accent` | warm sand `#d3c0aa` → `oklch(80% 0.035 78)` | The lone warm note — the amber window. Use sparingly. |
| `base-100` | white | Page & card background |
| `base-200` | cool near-white | Subtle section fills |
| `base-300` | cool light gray | Borders, hairlines |
| `base-content` | midnight ink `#004865` → `oklch(30% 0.055 233)` | Primary text |
| `success` / `warning` / `error` | green / honey-amber / red | Status |

The palette is teal-blue, **no purple** — night over water. Chroma is kept low
on purpose; calm reads as desaturated. The warm sand is the one deliberate
warmth held inside the cool — reserve it for a genuine accent, never decoration.

Body text on white uses `base-content`; secondary text uses
`text-base-content/70`, muted labels `text-base-content/60`.

## Typography

One ramp, named by role. Every size, line-height, and letter-spacing lives in
the scale — markup names a role, never a pixel. Tokens are defined in
`assets/css/app.css` under the type-scale `@theme` block.

### The two faces

| Face | Token | Stack | Used for |
| --- | --- | --- | --- |
| Display | `font-display` | **Newsreader** (editorial serif) | Hero, headings, and money figures. Sits at `font-normal` (400) — the serif reads contemplative when it isn't pushed bold. |
| Body | `font-sans` (default) | **DM Sans** | Everything else: reading copy, UI, labels. |

Both load via Google Fonts in `root.html.heex`. Display is the voice; sans is
the workhorse. Don't introduce a third face.

**Weight is the signature.** Lean light: display headings `font-display
font-normal tracking-tight`; sub-section headings (inside cards) DM Sans
`font-semibold tracking-tight`; body copy `font-light`; labels, table data,
badges, buttons `font-medium` / `font-semibold`.

### The scale

Tailwind v4 generates a `text-{role}` utility from each step, with line-height
and tracking **bundled in** — `text-body` already carries its `1.7` leading,
`text-eyebrow` its `0.2em` tracking. You almost never write `leading-*` or
`tracking-*` next to a type class.

Display steps use `clamp()`, so they scale with the viewport and need **no
responsive variants** (`sm:text-*`).

| Role | Class | Size | Use |
| --- | --- | --- | --- |
| Hero | `text-hero` | 3.25 → 5.25rem | The one H1 per page. |
| Statement | `text-statement` | 3 → 4.5rem | Closing CTA, big editorial lines. |
| Heading 2 | `text-h2` | 2.25 → 3rem | Section headings. |
| Heading 3 | `text-h3` | 1.875 → 2.5rem | Sub-section / card-cluster headings. |
| Heading 4 | `text-h4` | 1.25rem (fixed) | Card titles, list-item headings. |
| Lead | `text-lead` | 17px | Hero sub, section intros. |
| Body | `text-body` | 15px | Default reading copy. |
| Small | `text-small` | 13px | Dense copy, list rows, mockup titles. |
| Fine | `text-fine` | 12px | Metadata, timestamps, table meta. |
| Micro | `text-micro` | 11px | Captions, footnotes, smallest readable text. |
| Eyebrow | `text-eyebrow` | 11px · 0.2em | Uppercase section kickers. Pair with `.text-moon`. |
| Label | `text-label` | 11px · 0.14em | Uppercase UI micro-labels in product chrome. |

Display roles (`hero`…`h3`) pair with `font-display`; eyebrow/label expect
`uppercase font-semibold` alongside — the token only owns size, line-height,
and tracking.

### Money & figures

Numerals are set in the **display serif** with `tabular-nums` so columns of
rupees align. Reuse a body step for the size and add `leading-none` for
single-line figures:

```heex
<p class="font-display text-lead leading-none tabular-nums">₹4,82,150.00</p>
```

`tabular-nums` and `leading-none` are the only line-height overrides you should
routinely pair with a type class — figures are the exception that proves the rule.

### Type rules

- **Name the role, not the pixel.** Never `text-[13.5px]`. If nothing fits, fix
  the scale, don't add a one-off. `mix nila.style_guard` fails the build on raw
  sizes (`text-sm`, `text-[Npx]`, stray `tracking-[…]`/`leading-[…]`) in
  `lib/nila_web`.
- **No `leading-*` / `tracking-*` next to a type class** (already bundled);
  exceptions above.
- **No `sm:text-*` on display roles** — the `clamp()` is the responsive behavior.
- **One face per job.** Serif for display and figures, sans for everything else.
- **`font-normal` on the serif.** Weight comes from size, not ink.

### Migrating legacy markup

Older interior pages still carry arbitrary `text-[Npx]` with hand-tuned
leading/tracking, and legacy slate colors. When you touch one of those screens,
map each size to its nearest step and delete the redundant leading/tracking —
drift to fix on contact, not a pattern to copy. Default mappings (prefer intent
when a site clearly differs):

| Raw Tailwind | Role |
| --- | --- |
| `text-base` | `text-body` (paragraph); `text-h4` only if a real heading |
| `text-sm` | `text-small` (dense UI); `text-body` only for genuine reading copy |
| `text-xs` | `text-fine` (inline labels/hints/badges); `text-micro` for timestamps/metadata |
| `text-lg` | `text-h4` (heading) or `text-lead` (intro copy) |
| `text-xl` | `text-h4` |
| `text-2xl` | `text-h4` (card/auth heading) or `text-h3` (page title) |
| `text-3xl` | `text-h3` |
| `text-4xl` | `text-h2` |
| `text-5xl` | `text-statement` (hero) or `text-h2` |
| `text-[10px]` / `text-[11px]` | `text-micro` |
| uppercase kicker + `tracking-[0.2em]` / `.text-moon` | `text-eyebrow` (drop the tracking) |
| uppercase micro-label + `tracking-wide`-ish | `text-label` (drop the tracking) |

A **compact title** authored at `text-sm`/`text-base` stays compact — its
`font-semibold` carries the heading. Only `text-lg`+ titles climb the display
ramp. Money/KPI **figures** keep their size bucket (a `text-4xl` figure becomes
`text-h2`/`text-h3`, not `text-h4`) and retain `tabular-nums`/`leading-none`.

## Radius & borders

Set in the theme: fields/buttons `0.5rem`, cards (`rounded-box`) `0.875rem`,
borders `1px`. Use `rounded-box` for cards and `rounded-field` for small chips.
Borders are 1px `base-300` hairlines — quiet, never heavy.

## Signature utilities

Defined in `assets/css/app.css`. **Reuse these — do not invent one-off
gradients or shadows.** The look comes from restraint.

| Class | Use |
| --- | --- |
| `.moonlight` | The hero ground: a pale cool wash with a soft pool of light up top, fading to near-white. Pair with **ink** text, not white. |
| `.moonlight-soft` | An even quieter wash for section backgrounds. |
| `.text-moon` | Low-chroma sea-blue clipped to text — eyebrows, figures, accents. It whispers. |
| `.shadow-moon` | Soft layered elevation in the night-ink hue. Default card shadow. |
| `.shadow-moon-lg` | Heavier lift for floating/primary surfaces. |

## Patterns

- **Cards**: `rounded-box border border-base-300 bg-base-100 p-5 shadow-moon`.
- **Hero**: a `.moonlight` ground with **ink** (`text-base-content`) headline —
  light text on light. Content cards below overlap it (`-mt-28`) for depth.
- **Primary button**: daisyUI `btn btn-primary` (sea blue) + `shadow-moon`.
- **Sticky header**: translucent `bg-base-100/80 backdrop-blur` + 1px bottom border.
- **Status**: `badge badge-primary badge-soft` for soft pills.

## Don't

- Don't hard-code hex colors in markup — use theme tokens.
- Don't use raw Tailwind sizes or arbitrary `text-[Npx]`/`tracking-[…]`/`leading-[…]`
  — name a role from the scale.
- Don't pair `leading-*`/`tracking-*` with a `text-{role}` (exceptions:
  `leading-none`/`tabular-nums` on figures).
- Don't reach for heavy headings (`font-bold` on display type) — stay light.
- Don't add bespoke gradients/shadows — use the utilities above.
- Don't add a dark theme or `tailwind.config.js`.
