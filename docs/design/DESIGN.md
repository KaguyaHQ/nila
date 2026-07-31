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

The public pages are set as a leaf from an account book: warm paper
(`bg-paper`), true ink (`text-ink`), feint blue ruling (`border-feint`), the
double red margin rule (`redink`), and double rules opening/closing the leaf.
Those four tokens live in `app.css` under "Ledger (marketing identity)" and are
for marketing surfaces only — product screens stay on moonlight below. Red ink
means exactly one thing there: a line waiting on a human.

**The ledger is a setting, not a second brand.** Every one of the four values is
cut from a hue moonlight already uses, so crossing from `/` into the product
changes the room, not the palette:

| Token | Value | Its moonlight counterpart |
| --- | --- | --- |
| `paper` | `oklch(97.6% 0.005 78)` | `accent` (hue 78) at half chroma — the page's warmth is the brand's one sanctioned warm note, kept to a whisper because a tint that reads as an accent on a badge reads as cream across a whole page |
| `ink` | `oklch(23% 0.045 233)` | `base-content` (`30% 0.055 233`) pressed darker for ink on paper |
| `feint` | `oklch(89.5% 0.02 233)` | `base-300`'s hue, chroma held higher — feint blue ruling has to read blue |
| `redink` | `oklch(50% 0.17 22)` | `error` exactly, at 50% L not 60% — the margin rule and `text-micro` flags need the contrast on paper |

What the ledger keeps as its own is **structure, not color**: zero radius on
rules and tables, 4px double borders, the red margin rule, ruled rows. Only the
things a visitor clicks — buttons — take the theme's `rounded-field`, so the CTA
on marketing matches the button waiting after log-in.

All four public pages render through `<.page_shell>` in
`lib/nila_web/controllers/page_html.ex`. It owns the paper, the header, the
margin rule, and the footer. Add a marketing page by wrapping its body in the
shell — never by re-declaring the chrome.

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
| `scrim` | near-black `oklch(20% 0.012 233)` | Full-screen document reader only |
| `success` / `warning` / `error` | green / honey-amber / red | Status |

The palette is teal-blue, **no purple** — night over water. Chroma is kept low
on purpose; calm reads as desaturated. The warm sand is the one deliberate
warmth held inside the cool — reserve it for a genuine accent, never decoration.

#### Ink scale

Four named utilities define text emphasis. They use the same alpha-over-base
mechanism as Tailwind's color opacity modifiers, preserving how ink composites
on tinted surfaces.

| Utility | Alpha | Role |
| --- | --- | --- |
| `text-ink` | 100% | Primary content: headings, table numbers, and anything read as the data. Usually inherited; use it to re-assert full ink inside a muted parent. |
| `text-ink-muted` | 70% | Supporting prose: full sentences, account lines, and descriptions. This is the floor for sentences. |
| `text-ink-subtle` | 60% | Labels and metadata: column headers, fold summaries, eyebrows, timestamps, and field labels. Short strings, not prose. |
| `text-ink-faint` | 40% | Non-text glyphs only: chevrons, decorative icons, disabled affordances, and placeholder-grade marks. Never words. |

**Sentences live at `text-ink` or `text-ink-muted`.** `text-ink-subtle` may
label; it may not narrate. **`text-ink-faint` never carries words.** If a word
wants to be faint, it is either subtle or it should not be on the screen.

Raw `text-base-content/NN` is banned. A new emphasis level requires editing the
scale in `app.css` and this reference, not typing a number. Variant prefixes
compose as usual: `hover:text-ink`, `group-open:text-ink-subtle`, and so on.

**Dimming.** An overlay that keeps its page readable underneath uses
`base-content` at low opacity (`<.modal>`: `/40`). One that replaces the page to
show a document uses `scrim` — `base-content` is a real blue, and at full
opacity it tints the paper inside it.

#### Ruling

**Ordinary product ruling is a 1px `base-300` hairline.** This includes card and
control outlines, table rules, separators, and dividers. Do not soften ruling
with `base-200` or synthesize another line color from `base-content/NN`.

Semantic status borders (`success`, `warning`, `error`, `primary`), interactive
hover and drag-target borders, dark-ground ruling such as the navigation rail's
`base-100/10`, and structural accent bars are not ordinary ruling and keep their
semantic color or weight. Marketing ledger rules remain on `ink`, `feint`, and
`redink`. `mix nila.style_guard` enforces the product ruling rule.

#### Elevation

**A shadow means the surface is floating above the page.** Use `shadow-moon` for
dropdowns, popovers, and toasts; use `shadow-moon-lg` for modals. These are the
only two shadow utilities in the product; do not mint ad-hoc `shadow-*` values.

Anything in normal document flow — cards, stat tiles, tables, panels, chips,
avatars, and selected rows — uses a `base-300` hairline, a semantic tint, or an
inset ring instead, never a shadow. Six shadowed reference surfaces rank
nothing; unequal spacing and restrained fills must create their grouping.

#### Spacing

Structural rhythm has four named roles. The names describe the relationship,
not the container or direction; use them with `space-y-*`, `gap-*`, or a
structural margin when a parent cannot own the gap.

| Role | Utility suffix | Value | Carries |
| --- | --- | --- | --- |
| Related | `related` | 8px | Pieces of one thought: label + help, heading + list |
| Block | `block` | 16px | Fields and sibling blocks inside one component |
| Section | `section` | 24px | Distinct panels, folds, and ordinary page sections |
| Region | `region` | 32px | Major workbench regions only |

**The parent owns spacing between siblings.** Components own their internal
geometry; callers own the gap around the component. Outer gaps must be larger
than inner gaps: related < block < section < region. Prefer `gap-*` or
`space-y-*` over stacking child margins. Responsive spacing changes at page or
region boundaries, not inside rows and controls.

Numeric primitives remain legitimate inside components: 4, 8, 12, 16, 24, 32,
and 48px, with 2px and 6px reserved for optical micro-alignment. Compact rows
use `px-3 py-2`; standard rows use `px-4 py-3`; standard cards and modals use
`p-6`. Product page gutters are `px-4 sm:px-6 lg:px-8`. Worklists and working
sheets use compact geometry; review, correction, and signing surfaces use
standard geometry. This is a recipe choice owned by the shared component, not a
screen-level density toggle.

Raw numeric `space-y-2/4/6/8`, arbitrary spacing (`p-[…]`, `gap-[…]`, etc.),
and off-scale numeric spacing are banned in product markup. Name structural
rhythm and keep optical exceptions inside components. `mix nila.style_guard`
enforces the closed scale.

#### Motion

Product transitions have two speeds and one standard easing curve. Bare
`transition`, `transition-colors`, and `transition-transform` use the fast
system default; write `duration-calm` only for deliberate spatial movement.

| Role | Utility | Duration | Use |
| --- | --- | --- | --- |
| Fast | default / `duration-fast` | 150ms | Hover, focus, folds, chevrons, selection, floating-surface exit |
| Calm | `duration-calm` | 300ms | Modal entrance and navigation-rail geometry |

Both use `ease-standard`, the default `cubic-bezier(0.4, 0, 0.2, 1)`. Named
attention effects are separate from transitions: the 1.4s workings ripple must
remain visible long enough to identify recalculated nodes. Continuous spinner
and pulse animations retain their physical timing. Marketing's `moon-rise` is
also outside the product transition scale.

Numeric `duration-*` and raw `ease-in` / `ease-out` / `ease-in-out` utilities
are banned in product markup. Reduced-motion behavior is mandatory and lives in
`app.css`. `mix nila.style_guard` enforces the named transition vocabulary.

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
- **Tables**: `<.data_table>` is the only table. `dense` for working-sheet
  material read in bulk; `flat` (no shadow) for reference tables — elevation
  ranks a table as holding a decision, and six shadowed surfaces in one section
  rank nothing. Right-aligned columns get `tabular-nums` automatically.
- **Disclosures**: `<.fold>`, never a bare `<details>`. A browser-toggled
  `<details>` does not survive a LiveView patch — morphdom syncs `open` away, so
  a section the reader opened slams shut the next time anything arrives. The
  component takes `open` from server state and pushes `toggle-fold`.
- **Two expand marks, one meaning each.** A trailing chevron-down that rotates
  180° means a *section* folds. A leading chevron-right that rotates 90° means a
  *row* expands in place. Never mix them in one surface.

## Don't

- Don't hard-code hex colors in markup — use theme tokens.
- Don't use raw Tailwind sizes or arbitrary `text-[Npx]`/`tracking-[…]`/`leading-[…]`
  — name a role from the scale.
- Don't pair `leading-*`/`tracking-*` with a `text-{role}` (exceptions:
  `leading-none`/`tabular-nums` on figures).
- Don't reach for heavy headings (`font-bold` on display type) — stay light.
- Don't add bespoke gradients/shadows — use the utilities above.
- Don't add a dark theme or `tailwind.config.js`.
