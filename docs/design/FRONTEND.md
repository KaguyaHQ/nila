# Frontend system

Read this for token, class, component, layout-shell, or mechanical UI work. Read
[`COMPOSITION.md`](./COMPOSITION.md) before designing or substantially restructuring a
screen. [`DESIGN.md`](./DESIGN.md) holds the durable product principles.

## Sources of truth

- `assets/css/app.css` — authoritative token values, fonts, theme, and signature utilities.
- `lib/nila_web/components/` — authoritative component APIs and internal recipes.
- `lib/nila_web/components/layouts.ex` — product shell and responsive outer geometry.
- `/dev/design-system` — development-only executable reference built from real components
  and static accounting specimens.
- `mix nila.style_guard` — mechanically enforced token, spacing, ruling, motion, and
  restricted-context rules.

Do not duplicate numeric token values in Markdown or markup. This document explains
roles and constraints; inspect the executable source for exact values.

## Necessity gate

This document governs how an element is implemented, not whether it should exist. Apply
the deletion test in [`OPINIONS.md`](./OPINIONS.md) first. A component's availability is
never a reason to use it. Labels, badges, cards, folds, states, motion, and interactions
all impose cognitive cost; include one only when removing it would prevent the user from
obtaining or understanding the result.

## Stack and shell

Nila uses Phoenix LiveView, Tailwind v4, daisyUI v5 token plumbing, and one light-only
theme. **Pinned Radix Themes 3.3 is the color and mechanical authority for generic UI.**
It is not a runtime dependency: its coordinated semantic colors, geometry, and states are ported into Nila's HEEx
components. DaisyUI component classes are not product APIs. Keep the Tailwind v4
import/source syntax in `app.css`; there is no `tailwind.config.js`. Only `app.js` and
`app.css` are supported bundles.

When Radix does not define a higher-level generic pattern, use shadcn as the anatomy and
interaction reference, then express it with Nila's existing components and Radix-calibrated
tokens. Do not import shadcn's theme or styling wholesale. In shorthand: **shadcn anatomy,
Radix physics, Nila composition.** Radix wins for generic color relationships, radius,
borders, elevation, control spacing, and control states. Nila owns product composition,
typography, and the explicitly registered brand exceptions below.

For dense professional application patterns, use Primer as the behavior and state-model
reference when it is more specific than Radix. In particular, searchable single-select lists
follow [Primer ActionList](https://primer.style/product/components/action-list/guidelines/) and
[SelectPanel](https://primer.style/product/components/select-panel/guidelines/): keyboard-active,
pointer hover, and persisted selection are distinct states. Primer does not supply Nila's visual
tokens or component geometry.

`Layouts.app/1` owns the desktop rail, product canvas, mobile fallback header, and outer
gutters. `Layouts.settings/1` adds settings navigation inside that shell. Pages compose
inside the layout and do not recreate chrome or add a second page gutter.

Shared components own internal geometry. Callers own composition and gaps around them.
A repeated domain relationship—coverage, reconciliation, sequence—is not a generic
cockpit abstraction and belongs in `components/` when it recurs.

## Color authority and ink

Use semantic Tailwind tokens; never raw hex, OKLCH, palette utilities, or arbitrary neutral
mixtures in product markup. `app.css` pins the exact Radix Themes 3.3 light contract with
Slate as `grayColor`. The isolated upstream reference lives at
`tmp/design-references/radix-themes-reference`; it is evidence, not a production dependency.
`mix nila.style_guard` pins the normalized Radix substrate/status blocks and every registered
authored-pigment block by SHA-256. Updating one is a deliberate source migration: compare the
upstream 3.3 source or owned artwork, update the rendered reference, then update the digest.

| Role | Use |
| --- | --- |
| `canvas` | Page/work-area background (`--color-background`) |
| `panel-surface` | Solid card, table, dialog, and popover panel |
| `panel-translucent-surface` | Deliberately translucent floating or sticky panel |
| `control-surface` | Input and select surface |
| `quiet` | Non-interactive quiet fill and table header |
| `interactive` | Neutral hover/open fill |
| `rule` | Ordinary border, row rule, and divider |
| `inverse` | Text, icons, and translucent fills on brand-dark chrome |
| `primary` | Primary action and interactive emphasis from Nila blue |
| `info`, `success`, `warning`, `error` | Pinned Radix semantic feedback families |
| `scrim` | Strong document-reader overlay only |

The daisyUI `base-*` tokens are compatibility aliases required by the plumbing, not product
composition APIs. New or migrated markup must use the roles above. Generic component recipes
consume Radix variables directly (`--gray-*`, `--color-panel-solid`, `--color-surface`, and
the pinned shadow scale).

The only permitted authored pigments are registered here:

| Exception | Owner | Scope and justification |
| --- | --- | --- |
| Validated Nila blue scale | Brand | `accent`, focus, primary actions, and restrained brand emphasis; generated as a coordinated scale and contrast-tested |
| `.moonlight-night` | Brand chrome | Persistent navigation rail and deliberate marketing inverse composition; never a generic panel |
| `.moonlight` | Brand atmosphere | Scoped pale brand ground for deliberate hero/error/reference compositions; never a reusable product surface or component state |
| `.landing-*` artwork | Marketing | Scoped authored illustration/composition; never reusable product surfaces or component states |
| Newsreader and Switzer | Typography | Brand typefaces; unrelated to generic color relationships |

No other custom pigment is implicitly grandfathered. A new exception requires a named owner,
a scope that cannot be satisfied by Radix, rendered evidence, contrast verification, and an
update to this registry plus `mix nila.style_guard`.

The ink scale is executable, not a naming convention. `--nila-ink-12` and the
`--nila-ink-a*` steps alias Radix `--gray-*`; accent and feedback colors have corresponding
coordinated steps. Utilities and closed component recipes consume those variables directly.

- `text-base-content` / ordinary inherited ink — required words and values;
- `text-ink-muted` — supporting explanations, backed by `--nila-ink-a11`;
- `text-ink-subtle` — context and schema that may recede;
- `text-ink-faint` — icons, rules, and decorative marks only, never words.

A theme context that changes `base-content` must redeclare the complete ink scale rather
than one primitive. Never infer a CSS variable from a utility name: every `var(--…)`
reference must have an executable definition and `mix nila.style_guard` enforces that.
Do not tint every sentence blue. Blue is available for meaning because ordinary text
stays ink.

## Typography

The memorable rule is in `DESIGN.md`: **16px to read, 14px to work, 12px for context.**
The exact scale lives in `app.css`; Tailwind generates role utilities with line-height
and tracking bundled in.

| Role | Class | Use |
| --- | --- | --- |
| Hero / statement / h2 / h3 | `text-hero`, `text-statement`, `text-h2`, `text-h3` | Earned display moments, fluid with viewport |
| Heading 4 | `text-h4` | Product section and card titles |
| Lead | `text-lead` | Prominent introduction |
| Body | `text-body` | Explanations and workflow sentences |
| UI | `text-ui` | Forms, tables, buttons, navigation, statuses, identifiers, totals |
| Context | `<.context_text>` | Timestamp, provenance, source/page attribution, tertiary history |
| Label | `text-label` | Column headers and compact schema/group labels |
| Eyebrow | `text-eyebrow` | Uppercase marketing kicker only |

`text-context` is deliberately unavailable at call sites. The `<.context_text>` primitive
owns it, and `style_guard` rejects raw use. Do not use context merely because information
looks secondary. Operational values remain `text-ui`.

`text-label` is schema, not data. An invoice number, period, document abbreviation,
status, and control total are data. Badges are operational UI and remain 14px.

Newsreader (`font-display`, normally `font-normal`) is the display face. Switzer is the
workhorse. Use serif for earned display moments and money figures, not ordinary product
copy. Figures may pair a role with `leading-none` and `tabular-nums`; otherwise do not
add custom leading or tracking to type roles.

Never use raw `text-xs`, `text-sm`, `text-base`, arbitrary sizes, or retired type steps.
If a role does not fit, fix the system rather than minting a pixel.

## Money and figures

Use Nila formatters for Indian digit grouping. Right-align numeric table columns;
`<.data_table>` applies tabular figures to aligned columns. A focal money figure may use
`font-display` with an existing body/display role, `font-normal`, `leading-none`, and
`tabular-nums`.

A number is a claim. Its label and basis must survive skeptical arithmetic. Never use a
large figure merely because it is available.

## Spacing and density

Structural spacing names relationships:

| Role | Utility suffix | Carries |
| --- | --- | --- |
| Related | `related` | Pieces of one thought |
| Block | `block` | Fields and sibling blocks inside a component |
| Section | `section` | Distinct panels, folds, and ordinary sections |
| Region | `region` | Major workbench regions |
| Canvas | `canvas` | Separate questions on the page |

The parent owns spacing between siblings. Components own their internal padding.
Outer gaps exceed inner gaps. Product gutters use the shared layout recipe. Raw numeric
structural stacks and off-scale spacing fail `style_guard`.

Table geometry is selected by the table's job, not assembled from independent density
and alignment switches. `scan` uses compact geometry for registers and numeric schedules;
`worklist` uses standard, vertically centred rows for tasks and destinations; `review`
uses standard, top-aligned rows for multiline evidence and embedded controls. All three
remain 14px working UI.

## Ruling, radius, and elevation

Ordinary product borders and dividers use the `rule` hairline. Card-like containers
use `rounded-box`; interactive controls use `rounded-field`. Exact radius and border
values live in `app.css`.

A shadow means a surface floats above the page. Use `shadow-moon` for dropdowns,
popovers, and toasts; `shadow-moon-lg` for modals. Normal-flow cards, tables, chips,
selected rows, and panels use spacing, fills, or ruling rather than elevation. This is a
strong default; aesthetic exceptions require rendered evidence and a system update.

## Motion

Use the named fast/calm timing and standard easing from `app.css`. Fast handles hover,
focus, folds, chevrons, and selection. Calm is for deliberate spatial movement such as
rail geometry or modal entrance. Numeric durations and raw easing fail `style_guard`.

Respect reduced motion. Named attention effects such as a finite workings ripple are
allowed only when motion is necessary to locate or understand a state change. Product
motion reveals or confirms, then stops; delight alone never justifies it.

## Signature utilities

These are defined in `app.css`; reuse them rather than inventing one-off treatments.

| Utility | Use |
| --- | --- |
| `.moonlight` | Hero ground: pale cool wash and soft light |
| `.moonlight-night` | Persistent midnight-sea shell ground |
| `.text-moon` | Validated Nila blue brand emphasis |
| `.shadow-moon` | Compatibility alias to Radix floating elevation |
| `.shadow-moon-lg` | Compatibility alias to Radix modal elevation |

## Shared component contracts

- **Cards:** `<.card>` owns surface, border, radius, and controlled padding. Callers may
  compose content but may not reskin the surface.
- **Stat tiles:** `<.stat_card>` owns label/value/caption and optional figure treatment.
- **Buttons:** `<.button>` owns variant, compact/standard/prominent size, icon spacing,
  focus, and disabled state. Product callers cannot pass styling classes.
- **Segmented controls:** `<.segmented_control>` owns mutually exclusive operational
  filters; never rebuild joined button groups.
- **Badges:** `<.badge>` owns semantic status styling and 14px operational type. It has one
  size and no styling escape hatch.
- **Fields:** `<.input>` owns text, select, textarea, checkbox, date, password, labels,
  errors, and control geometry. Callers supply content and native attributes, not classes.
- **Tables:** `<.data_table>` is the only product table and requires one closed mode:
  `scan`, `worklist`, or `review`. The mode owns padding and vertical alignment; callers
  cannot recombine those decisions. Exactly one column is the semantic `row_header`, and
  right-aligned columns are tabular automatically. Radix supplies physical calibration.
  Mature data-table systems such as Primer may inform higher-level behaviour where Radix
  has no opinion, but the resulting decision must be encoded in Nila's component rather
  than delegated to product callers.
- **Context:** `<.context_text>` is the only route to 12px contextual copy. Its controlled
  API prevents competing type roles.
- **Folds:** `<.fold>`, never bare `<details>`. Open state lives on the server so LiveView
  patches do not collapse the reader’s place. `<.fold_summary>` owns 14px title/detail
  typography for operational summaries.
- **Modals and sheets:** `<.modal>` owns scrim, width families, radius, elevation, focus,
  dismissal, sheet side placement, and workbench mode. Use `variant="sheet"` for a focused
  task attached to a viewport edge; its anatomy follows shadcn Sheet while its visual physics
  remain Nila/Radix. Callers cannot pass arbitrary panel classes. Put ordinary dialog
  actions directly in `:footer`, secondary action first; the component owns alignment,
  spacing, and wrapping. Body forms use `form="form-id"` on footer submit buttons.
- **Menus:** transient action menus use the native `popover="auto"` contract for light
  dismissal and Escape behavior; `<details>` is a disclosure primitive, not a dropdown.
- **Searchable single-select lists:** use the shared `SelectableList` hook. Keep focus in a
  combobox input, expose the virtual option through `aria-activedescendant`, and use
  listbox/option semantics. Arrow keys, Home/End, Page Up/Page Down, and Enter stay client-side; a
  server-filtered form must also provide a `phx-submit` fallback so Enter cannot become a browser
  reload. Render choices with `<.selectable_listbox>` and `<.selectable_option>`: hover and
  keyboard-active use the neutral interaction fill, selected uses the accent selection fill, and
  selected plus active uses the stronger accent fill. Only the combobox draws the focus ring.
- **Feedback:** `<.callout>`, `<.spinner>`, and `<.progress_bar>` own status mechanics;
  `<.flash>` owns floating notifications.
- **Forms:** `<.input>` for every field, `to_form/2`, and unique form/control IDs.
- **Icons:** `<.icon>`, never direct Heroicons modules.

A trailing chevron-down rotating 180° means a section folds. A leading chevron-right
rotating 90° means a row expands in place. Do not mix those gestures.

## Visible UI workflow

For user-visible changes:

1. State the required user outcome and delete every element it does not require.
2. Inspect the current affected desktop screen.
3. Inspect analogous components/screens and this document.
4. Reuse components and tokens for what survived; do not add a component to complete a
   familiar pattern.
5. Implement the smallest faithful change without adjacent improvements.
6. Run `mix nila.style_guard` and focused tests.
7. Render the actual desktop screen at a CA-firm working width.
8. Inspect hierarchy, type at actual scale, density, clipping, empty regions, and state.
9. Delete once more before completion.

Routine mobile inspection is not required. Perform a narrow-screen smoke check only when
shared layout or shell changes plausibly risk catastrophic breakage.

## Mechanical prohibitions

- No hard-coded generic colors, raw type sizes, arbitrary tracking/leading, or invented dark theme.
- No neutral `color-mix()` outside an exact pinned Radix recipe. Authored marketing artwork is scoped by the exception registry.
- No `@apply`, `tailwind.config.js`, or external script/link tags in layouts.
- No one-off gradients or shadows outside the named system.
- No raw `text-context`; use `<.context_text>`.
- No bare `<details>`, raw product `<input>`, or duplicate component recipes.
- No raw daisyUI component classes in product code; daisyUI is theme plumbing only.
- Closed `nila-*` recipes belong to their component owner and fail `mix nila.style_guard`
  when copied into product markup.
- Undefined CSS custom-property references fail `mix nila.style_guard`; a Tailwind utility
  does not create an identically named runtime variable.
- Do not add exceptions to a guard allowlist merely to silence a violation.
