# Nila design

This is the entry point for product design work. It holds the durable identity,
product principles, and the small set of invariants every UI task needs. Load the
deeper document only when the task calls for it.

Read [`OPINIONS.md`](./OPINIONS.md) before every visible product change. It decides
whether an element should exist. The documents below govern only what survives that test.

| Task | Read next |
| --- | --- |
| Token, class, component, or mechanical UI edit | [`FRONTEND.md`](./FRONTEND.md) |
| New screen, workflow, or substantial restructuring | [`COMPOSITION.md`](./COMPOSITION.md) and [`TASTE.md`](./TASTE.md) |
| Public or marketing page | [`MARKETING.md`](./MARKETING.md) and [`TASTE.md`](./TASTE.md) |
| Aesthetic judgment | [`TASTE.md`](./TASTE.md) |

`assets/css/app.css` is authoritative for token values. Shared component APIs live
under `lib/nila_web/components/`. Radix Themes 3.3 is the authority for generic
component physics; Nila ports those relationships into HEEx with moonlight colors and
its own typography. This document explains intent; it does not mirror executable values.

## Brand

**Nila** (நிலா) — the moon. Cyclical, calm, reliable, quiet. It works while the
firm sleeps; reflective rather than generative, it processes what already exists
and surfaces only what needs a human. That is the product: an AI accountant that
drafts the compliance back office in the background.

Traits become design:

- **Calm and graceful** — muted, low-glare surfaces; ink and whitespace carry the page.
- **Quiet** — restraint in size, weight, border, and motion; the data leads.
- **Reflective** — soft luminance over hard contrast.
- **Reliable** — the same states, tokens, and interactions mean the same thing everywhere.

Voice is plain, precise, and unhurried. No exclamation marks or growth-copy clichés.
The readers are CAs and their staff: professionals completing accountable work.

## Product principles

Nila drafts, the human reviews, the CA signs. Every screen answers to that loop.

- **Remove before arranging.** Every label, state, action, region, and interaction creates
  cognitive work. Add one only when the user's job cannot be completed or understood
  without it.
- **Absorb complexity.** Nila's internal model belongs in the system. Never make the user
  learn it merely because the implementation needs it.
- **Lead with what needs the human.** Show the exception pile and what blocks the close,
  not a feed, dashboard theatre, or another pitch for the product.
- **Arrive with the work done.** Records begin populated from their source documents.
  Review and correct; never transcribe.
- **Propose, then confirm.** A guess never looks like a fact, and uncertain business
  state does not commit without a human decision.
- **Prevent the error at creation.** Catch classification and tax errors in review,
  before they reach a filed return.
- **Put the work on the glass.** Show what the reviewer must weigh and defer what they
  do not. Missing hierarchy is as damaging as excess content.
- **Visual weight matches consequence.** Draft, reversible, approval, and irreversible
  actions must not look equivalent.
- **Match density to the moment.** Queues and working sheets can be tight; review and
  signing surfaces breathe.
- **Speak the operator's language.** Use words the accountant says aloud. Align figures,
  use Indian digit grouping, and never replace precision with a score.
- **Conceptual inevitability is beauty.** Visual pleasure cannot justify an unnecessary
  concept. The finished surface should feel as though nothing could be removed and
  nothing else needed to be added.

## Core invariants

These are not taste preferences. Violating one is almost certainly a product error.

- Phoenix owns business truth; UI state never implies a transition that was not recorded.
- If removing a visible element preserves the outcome, remove it.
- A visible state must change the user's next action; internal state alone is not a reason
  to expose it.
- Machine checks, human assurance, workflow state, and approval remain distinct.
- Unresolved work never appears verified, approved, reconciled, or complete.
- A number states its basis. Derived identity is not independent corroboration.
- Source evidence and attributed human actions remain connected to the result they support.
- Operational words and values use readable ink; faint ink never carries required meaning.
- Product UI is light-only moonlight: no purple, achromatic black, or invented dark theme.
- Markup uses semantic tokens and shared components; no raw colors or arbitrary type sizes.
- Generic controls follow the pinned Radix family; product code never invents or overrides
  their geometry.
- Twelve-pixel text is restricted context, never a way to make operational information
  look secondary.

## Typography in one rule

**16px to read. 14px to work. 12px for context.**

- `text-body` — explanations and workflow sentences a person must read.
- `text-ui` — controls, tables, statuses, totals, identifiers, and the working default.
- `text-context` — timestamps, provenance, source/page attribution, and tertiary history;
  it is available only through `<.context_text>`.
- `text-label` — column headers and compact schema/group labels.

Importance decides the role, never the datatype or visual position. An invoice number,
GSTIN, reconciliation status, or control total is working information even when it sits
under a title. A timestamp remains context even when it is numeric.

## Visual character

The room is cool near-white moonlight with deep midnight-sea ink and one restrained
warm note. Low chroma, low glare, delicate type, and quiet ruling create calm. Newsreader
is the display voice for earned human moments and figures; Switzer carries the work.
Persistent chrome may hold one quiet brand ground. Visual authorship styles necessary
work; it never earns an additional element.

Use whitespace and hierarchy before adding boxes. Borders are subordinate structure,
not the composition. Shadows mean a surface floats. Motion reveals or confirms a spatial
change, then becomes still.

## Rule kinds

- **Invariants** protect truth, assurance semantics, accessibility, and the product loop.
  Encode them in components, tests, or `mix nila.style_guard` where practical.
- **Defaults** make common work coherent. Follow them unless the composition has a concrete
  reason not to; record recurring exceptions by improving the component or guidance.
- **Taste** is judged in the rendered interface. [`TASTE.md`](./TASTE.md) records what the
  founder responds to and is not a lint specification.

## Completion loop for visible UI

1. State the user-visible outcome in one sentence.
2. Remove every proposed element that is not required to obtain or understand it.
3. Inspect the affected desktop screen, nearby components, and analogous surfaces.
4. Read the scoped guidance from the table above.
5. Implement the smallest faithful change with existing components and tokens. Do not
   improve adjacent areas.
6. Run `mix nila.style_guard` and focused tests.
7. Render the real affected desktop screen and inspect hierarchy, density, clipping,
   empty regions, and type at actual scale.
8. Delete once more before calling the work complete.

Nila is a desktop workbench for CA firms. Routine mobile parity and screenshots are not
a completion requirement. Check narrow layouts only when changing shared shell or layout
code that could otherwise break catastrophically.
