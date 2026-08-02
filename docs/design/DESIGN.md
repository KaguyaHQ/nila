# DESIGN.md — Nila

The single design reference: brand, product principles, **composition**, and the
**moonlight** visual system. Read this before editing `.heex` or components. It complements
`AGENTS.md` (Elixir/Phoenix rules). The founder's recorded taste — the standard
this system is judged against — lives in `TASTE.md` beside this file; read it
before any aesthetic call.

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
- **Put the work on the glass; subtract what doesn't support the judgement.**
  Show the material the reader has to weigh and defer what they don't. When a
  screen feels unclear the fault is as often missing hierarchy as excess
  content — establish what the eye lands on first before removing anything.
  Grouping and hierarchy should explain the screen, not instructional copy.
- **Visual weight matches consequence.** A draft looks like a draft;
  an irreversible action looks like a last resort, never an equal option next
  to a safe one.
- **Match density to the moment.** Queue lists are tight and glanceable — a row
  understood at once. Review surfaces breathe, because that's where a human
  makes a signing decision.
- **Speak the operator's language.** Labels are words they'd say out loud, not
  software jargon. Numbers are the product: tabular figures aligned down the
  column, Indian digit grouping always (₹12,50,000).
- **Calm is the aesthetic; pleasure is the test.** Their world is overload and
  relief is the deliverable — but a screen that is merely inoffensive has
  failed. The reviewer should want to look at it. Calm describes how the page
  behaves, and is never a licence for the page to be empty.

## Composition

Everything below this section is **materials** — color, size, weight, spacing,
radius, motion. Materials are not a screen. A page can name every token
correctly and still be a stack of boxes nobody wants to look at, and no rule in
the rest of this file will catch it. This section is the half that decides
whether the screen was designed.

**The material has to be on the glass, because looking is the task.** A product
screen is not a dispatcher handing out an action. A reviewer opens one to reach
conviction — that the month ties, that nothing is missing, that the figure is
safe to put a name to — and the signature is the last gesture, not the purpose.
Whatever they need in order to be convinced belongs where the eye reaches it
without a click.

### One focal assertion per surface

Every surface — page, card, panel — has one dominant assertion or relationship,
and it is the thing the reader came to verify. It may be a figure, a pair that
must agree, a residual, a document, or a decision. Rank by consequence, never
by what the element *is*:

> the assertion or relationship > its consequence or residual > its labels

On a wide verification workbench, the page title is chrome. `Breeze Tech · May
2026` at `text-h2` above the figures being signed at `text-lead` inverts the
screen: the grandest gesture is spent telling the reader where they already
know they are. Keep that title at `text-h4` or `text-lead` and give the display
step to the work when it earns it. Two values that must agree are one focal
relationship, not two competing surfaces.

### Show the shape, not only the sentence

A screen on which every element is prose has no glance state — a reviewer
asking "is this fileable?" has to read the whole page to find out. Draw a
relationship when its shape is faster to verify than aligned figures alone,
but keep the exact values and assertion visible. Visual encoding supplements
precision; it never replaces labels, numbers, or accessible text.

| Relationship | Visual form | Exact reading retained |
| --- | --- | --- |
| **Coverage** — how much of a whole is settled | Filled mass against its remainder | "247 of 252 purchase lines matched" |
| **A pair that must agree** — books vs 2B | Two figures set adjacent with the residual between them | Both figures and the residual |
| **A run that must be unbroken** — invoice series, months | The sequence drawn with its gaps visible | Range and named gaps |
| **Parts of a total** — tax heads, ITC buckets | Proportion only when it clarifies consequence | Every aligned amount |

Domain visual components are first-class and live in
`lib/nila_web/components/` like any other. Build one when a relationship
repeats; do not ship the sentence because no primitive existed.

### Fold summaries are assertions, not inventories

A closed fold is a claim that the reader need not look inside. State what kind
of evidence supports that claim rather than presenting every equality as an
independent check:

- **Tie-out** — independently derived values agree; show both and the residual.
- **Derived identity** — one artifact was produced from another, such as
  "GSTR-3B outward derived from this GSTR-1." It is provenance, not corroboration.
- **Coverage** — "247 matched · ₹12,40,318 reconciled" while unresolved rows
  remain outside the fold.
- **Inventory** — "The return · 2 parties · 1 rate · 3 HSN codes" does not
  justify hiding anything.

An inventory describes contents, which is precisely what a reader who trusts
the fold does not need. An assertion is what lets them not open it. **Fold what
has been verified; never fold what is unresolved.** Never claim a tie-out unless
Nila has two genuinely independent values to compare.

### An empty region does not render

A heading over an absence is worse than nothing: it spends a labelled region of
the page explaining why the region is empty. If a section has nothing to show
it is not on the page, and its state belongs in the one line that owns state.

The anti-pattern, in full:

> **SIGNATURES AND FILING**
> GSTR-1 signature waits: the GSTR-1 still has issues to check

### More than one plane

A wide verification workbench should use more than one density when supporting
state exists: the surface being verified, and a quieter rail or margin carrying
deadline, provenance, or consequence. A single centred `max-w-5xl` column on a
wide canvas can produce a document whose unused width reads as abandonment. Air
is the space *between* things; space after the last thing is just empty. Do not
invent a second plane for focused forms, authentication, upload, or mobile.

### One authored moment

Persistent chrome may carry one quiet brand ground, such as the midnight-sea
rail framing Nila's pale workspace. Each screen may add at most one
page-specific element that is drawn rather than assembled — a gradient ground,
a luminous surface, a bespoke mark — and it belongs to whatever the screen is
about. The shell establishes the room; the work remains its brightest object.

This is a licence, not a requirement. If a second page-specific moment appears,
one of them is decoration.

### Rhythm and air

Origin-scale separation between major subjects begins at 64px. `region` (32px)
is the current ceiling, which is why pages read as evenly packed rather than
composed. The scale gains one step:

| Role | Utility suffix | Value | Carries |
| --- | --- | --- | --- |
| Canvas | `canvas` | 64px | Between subjects the reader treats as separate questions |

Named steps are invisible to `mix nila.style_guard`'s numeric spacing check, so
`pt-canvas` and `space-y-canvas` need no linter change — only
`--spacing-canvas: 4rem` in `app.css`. Prefer responsive use such as
`gap-region lg:gap-canvas` when mobile does not need the full separation.

And vary it. Four regions at an identical gap is a list, and tells the reader
nothing about which boundaries matter.

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
| `redink` | `oklch(50% 0.17 22)` | `error` exactly, at 50% L not 60% — the margin rule and `text-meta` flags need the contrast on paper |

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

### Layout

`Layouts.app/1` owns the product shell: desktop rail, mobile header fallback,
page header, and responsive outer gutters. Product pages compose inside it and
never recreate that chrome or add a second page gutter. `Layouts.settings/1`
adds the settings navigation within the same shell.

Shared components own their internal geometry; LiveViews and domain components
own screen-specific composition. Prefer the existing table, card, fold, modal,
and page-header primitives over inventing a *generic* cockpit abstraction — but
a component that draws one specific relationship (a reconciliation, a coverage
proportion, an unbroken series) is not a generic abstraction, and belongs in
`components/`. See [Composition](#composition). Structural rhythm and density
are defined under [Spacing](#spacing).

### Color

Defined as the daisyUI `light` theme in `assets/css/app.css`. Use semantic
daisyUI/Tailwind tokens (`primary`, `base-content`, `base-300`…) in markup —
never hard-code hex.

| Token | Value | Role |
| --- | --- | --- |
| `primary` | sea blue `#316177` → `oklch(47% 0.06 232)` | Primary actions, links, accents |
| `secondary` | low-chroma slate `oklch(50% 0.018 258)` | Alternate semantic badges |
| `accent` | warm sand `#d3c0aa` → `oklch(80% 0.035 78)` | The lone warm note — the amber window. Use sparingly. |
| `neutral` | dark sea ink `oklch(33% 0.06 233)` | Quiet status and neutral controls |
| `info` | clear sea blue `oklch(55% 0.09 235)` | Informational status and feedback |
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
inset ring instead, never a shadow. Use spacing, fills, and semantic tints to
differentiate in-flow surfaces.

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
| Canvas | `canvas` | 64px | Between subjects the reader treats as separate questions. See [Composition](#composition) |

**The parent owns spacing between siblings.** Components own their internal
geometry; callers own the gap around the component. Outer gaps must be larger
than inner gaps: related < block < section < region < canvas. Prefer `gap-*` or
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
| Body | `font-sans` (default) | **Switzer** | Everything else: reading copy, UI, labels. |

Both are self-hosted from `priv/static/fonts` and declared with `@font-face` in
`assets/css/app.css`. Display is the voice; sans is the workhorse. Don't
introduce a third face or a runtime font CDN.

**Weight is the signature.** Lean light: display headings `font-display
font-normal tracking-tight`; sub-section headings (inside cards) Switzer
`font-semibold tracking-tight`; body copy `font-light`; labels, table data,
badges, buttons `font-medium` / `font-semibold`.

### The scale

Tailwind v4 generates a `text-{role}` utility from each step, with line-height
and tracking **bundled in** — `text-body` already carries its leading,
`text-eyebrow` its `0.18em` tracking. You almost never write `leading-*` or
`tracking-*` next to a type class.

The small end is deliberately blunt: **16px to read, 14px to work, 12px for
context.** Three sizes, three jobs, no 1px judgment calls.

Display steps use `clamp()`, so they scale with the viewport and need **no
responsive variants** (`sm:text-*`).

| Role | Class | Size | Use |
| --- | --- | --- | --- |
| Hero | `text-hero` | 3.25 → 5.25rem | The one H1 per page. |
| Statement | `text-statement` | 3 → 4.5rem | Closing CTA, big editorial lines. |
| Heading 2 | `text-h2` | 2.25 → 3rem | Section headings. |
| Heading 3 | `text-h3` | 1.875 → 2.5rem | Sub-section / card-cluster headings. |
| Heading 4 | `text-h4` | 1.25rem (fixed) | Card titles, list-item headings. |
| Lead | `text-lead` | 18px | Hero sub, section intros. |
| Body | `text-body` | 16px | Default reading copy and workflow sentences. |
| UI | `text-ui` | 14px | App UI, forms, tables, buttons, navigation — the working default. |
| Meta | `text-meta` | 12px | Timestamps, provenance, tertiary context. |
| Label | `text-label` | 12px · 0.04em | Column headers and compact group labels. |
| Eyebrow | `text-eyebrow` | 11px · 0.18em | Uppercase marketing kickers. Pair with `.text-moon`. |

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
  the scale, don't add a one-off. Reading copy and explanations use `text-body`;
  everything the operator works in is `text-ui`. `mix nila.style_guard` fails the
  build on raw sizes (`text-sm`, `text-[Npx]`, stray `tracking-[…]`/`leading-[…]`)
  and on the retired `text-table`/`text-small`/`text-fine`/`text-micro` steps.
- **`meta` is decided by importance, never by datatype.** An invoice number,
  GSTIN, or mismatch status is what the accountant came to check — that is
  `text-ui`. `text-meta` is for context that explains where or when the work
  arrived: "uploaded 12 minutes ago", "extracted from page 4", "source: WhatsApp".
- **`label` is schema, not data.** 12px semibold with light tracking for column
  headers and `<dt>`-style group labels. Ordinary form labels are sentence-case
  `text-ui` — uppercase tracking on "Invoice Number" is just shouting.
- **`tabular-nums` is targeted, not ambient.** Put it on amounts, dates, counts,
  and IDs that line up in a column. "Uploaded via WhatsApp" gains nothing.
- **No `leading-*` / `tracking-*` next to a type class** (already bundled);
  exceptions above.
- **No `sm:text-*` on display roles** — the `clamp()` is the responsive behavior.
- **One face per job.** Serif for display and figures, sans for everything else.
- **`font-normal` on the serif.** Weight comes from size, not ink.

## Radius & borders

Set in the theme: fields/buttons `0.5rem`, cards (`rounded-box`) `0.875rem`,
borders `1px`. Use `rounded-box` for card-like containers and `rounded-field`
for interactive elements such as buttons, links, toggles, and pills. Borders
are 1px `base-300` hairlines — quiet, never heavy.

## Signature utilities

Defined in `assets/css/app.css`. **Reuse these — do not invent one-off
gradients or shadows.** The look comes from restraint.

| Class | Use |
| --- | --- |
| `.moonlight` | The hero ground: a pale cool wash with a soft pool of light up top, fading to near-white. Pair with **ink** text, not white. |
| `.moonlight-soft` | An even quieter wash for section backgrounds. |
| `.moonlight-night` | The app shell's deep midnight-sea ground. Pair with `text-base-100`, never ink. |
| `.text-moon` | Low-chroma sea-blue clipped to text — eyebrows, figures, accents. It whispers. |
| `.shadow-moon` | Floating dropdown, popover, or toast elevation only. |
| `.shadow-moon-lg` | Modal elevation only. |

## Patterns

- **Cards**: `<.card>` owns `rounded-box border border-base-300 bg-base-100 p-6`.
  Callers add internal layout, never elevation or replacement geometry.
- **Stat tiles**: `<.stat_card>` owns compact `px-4 py-3` geometry; label, value,
  and caption structure; and an optional `figure` mode for large serif tabular KPIs.
- **Primary button**: `<.button>` with its default `primary` variant. Buttons
  remain in flow and do not cast shadows.
- **Sticky header**: translucent `bg-base-100/80 backdrop-blur` + 1px bottom border.
- **Status**: `<.badge>` with the semantic variant matching the business state.
- **Tables**: `<.data_table>` is the only table. Standard rows use `px-4 py-3`;
  `dense` is reserved for working-sheet material read in bulk. Tables are
  bordered in-flow surfaces and never cast shadows. Right-aligned columns get
  `tabular-nums` automatically.
- **Workpaper ownership**: sources sit with the evidence they produced; review,
  signature, and filing controls follow the return they attest. The page header
  owns month-level state, and evidence rows own their issues. Never collect
  those concerns into a detached support rail or duplicate issue queue.
- **Disclosures**: `<.fold>`, never a bare `<details>`. A browser-toggled
  `<details>` does not survive a LiveView patch — morphdom syncs `open` away, so
  a section the reader opened slams shut the next time anything arrives. The
  component takes `open` from server state and pushes `toggle-fold`. A fold is
  still not permission to hide verification material: the client-month
  workbench keeps its registers, workings, and source evidence on the glass.
- **Two expand marks, one meaning each.** A trailing chevron-down that rotates
  180° means a *section* folds. A leading chevron-right that rotates 90° means a
  *row* expands in place. Never mix them in one surface. Row expansion remains
  domain-owned; there is no shared row-expansion component.

## Don't

- Don't hard-code hex colors in markup — use theme tokens.
- Don't use raw Tailwind sizes or arbitrary `text-[Npx]`/`tracking-[…]`/`leading-[…]`
  — name a role from the scale.
- Don't pair `leading-*`/`tracking-*` with a `text-{role}` (exceptions:
  `leading-none`/`tabular-nums` on figures).
- Don't reach for heavy headings (`font-bold` on display type) — stay light.
- Don't scatter bespoke gradients — persistent chrome may keep one quiet brand
  ground, and each screen gets at most one page-specific authored moment for the
  work (see [Composition](#composition)). Everywhere else, reuse the signature
  utilities. Shadows are reserved for the floating surfaces named under Elevation.
- Don't add a dark theme or `tailwind.config.js`.
