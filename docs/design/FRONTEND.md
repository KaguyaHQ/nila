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

## Stack and shell

Nila uses Phoenix LiveView, Tailwind v4, daisyUI v5 token plumbing, and one light-only
`moonlight` theme. **Radix Themes 3.3 is the mechanical authority for generic UI.** It is
not a runtime dependency: its coordinated geometry and states are ported into Nila's HEEx
components. DaisyUI component classes are not product APIs. Keep the Tailwind v4
import/source syntax in `app.css`; there is no `tailwind.config.js`. Only `app.js` and
`app.css` are supported bundles.

When Radix does not define a higher-level generic pattern, use shadcn as the anatomy and
interaction reference, then express it with Nila's existing components and Radix-calibrated
tokens. Do not import shadcn's theme or styling wholesale. In shorthand: **shadcn anatomy,
Radix/Nila physics.** Radix/Nila always wins for spacing, type, color, radius, borders, and
elevation.

`Layouts.app/1` owns the desktop rail, product canvas, mobile fallback header, and outer
gutters. `Layouts.settings/1` adds settings navigation inside that shell. Pages compose
inside the layout and do not recreate chrome or add a second page gutter.

Shared components own internal geometry. Callers own composition and gaps around them.
A repeated domain relationship—coverage, reconciliation, sequence—is not a generic
cockpit abstraction and belongs in `components/` when it recurs.

## Color and ink

Use semantic daisyUI/Tailwind tokens; never raw hex or palette utilities in markup.
`app.css` defines the moonlight values.

| Role | Use |
| --- | --- |
| `base-100` | Bright content surface |
| `base-200` | Cool canvas and quiet fills |
| `base-300` | Ordinary borders and dividers |
| `base-content` | Primary midnight ink |
| `primary` | Primary action and interactive emphasis |
| `accent` | Rare warm note, never decoration by default |
| `info`, `success`, `warning`, `error` | Semantic state and feedback |
| `scrim` | Full-screen document reader only |

The ink scale is executable, not a naming convention. `--nila-ink-12` and the
`--nila-ink-a*` steps are Nila's Radix-calibrated foreground scale; accent and feedback
colors have corresponding coordinated steps. Utilities and closed component recipes
consume those variables directly.

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

Compact geometry is for worklists and working sheets. Standard geometry is for review,
correction, and signing. Density changes padding, not typography: dense tables remain
14px working UI.

## Ruling, radius, and elevation

Ordinary product borders and dividers use the `base-300` hairline. Card-like containers
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
separate from general transitions. Product motion reveals or confirms, then stops.

## Signature utilities

These are defined in `app.css`; reuse them rather than inventing one-off treatments.

| Utility | Use |
| --- | --- |
| `.moonlight` | Hero ground: pale cool wash and soft light |
| `.moonlight-soft` | Quieter section wash |
| `.moonlight-night` | Persistent midnight-sea shell ground |
| `.text-moon` | Low-chroma sea-blue accent text |
| `.shadow-moon` | Floating dropdown, popover, or toast |
| `.shadow-moon-lg` | Modal |

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
- **Tables:** `<.data_table>` is the only product table. Use `dense` only for material
  scanned in bulk; right-aligned columns are tabular automatically.
- **Context:** `<.context_text>` is the only route to 12px contextual copy. Its controlled
  API prevents competing type roles.
- **Folds:** `<.fold>`, never bare `<details>`. Open state lives on the server so LiveView
  patches do not collapse the reader’s place. `<.fold_summary>` owns 14px title/detail
  typography for operational summaries.
- **Modals and sheets:** `<.modal>` owns scrim, width families, radius, elevation, focus,
  dismissal, sheet side placement, and workbench mode. Use `variant="sheet"` for a focused
  task attached to a viewport edge; its anatomy follows shadcn Sheet while its visual physics
  remain Nila/Radix. Callers cannot pass arbitrary panel classes.
- **Menus:** transient action menus use the native `popover="auto"` contract for light
  dismissal and Escape behavior; `<details>` is a disclosure primitive, not a dropdown.
- **Feedback:** `<.callout>`, `<.spinner>`, and `<.progress_bar>` own status mechanics;
  `<.flash>` owns floating notifications.
- **Forms:** `<.input>` for every field, `to_form/2`, and unique form/control IDs.
- **Icons:** `<.icon>`, never direct Heroicons modules.

A trailing chevron-down rotating 180° means a section folds. A leading chevron-right
rotating 90° means a row expands in place. Do not mix those gestures.

## Visible UI workflow

For user-visible changes:

1. Inspect the current affected desktop screen.
2. Inspect analogous components/screens and this document.
3. Reuse components and tokens unless the relationship is genuinely new.
4. Implement the smallest coherent change.
5. Run `mix nila.style_guard` and focused tests.
6. Render the actual desktop screen at a CA-firm working width.
7. Inspect hierarchy, type at actual scale, density, clipping, empty regions, and state.
8. Fix visual problems before completion.

Routine mobile inspection is not required. Perform a narrow-screen smoke check only when
shared layout or shell changes plausibly risk catastrophic breakage.

## Mechanical prohibitions

- No hard-coded colors, raw type sizes, arbitrary tracking/leading, or dark theme.
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
