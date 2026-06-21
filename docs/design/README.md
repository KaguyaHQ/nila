# Design

Where Nila's design decisions live. Documents here describe how the product
looks, behaves, and is organized as an interface. Component implementation
lives in `lib/nila_web/components/`; this folder explains the *why* behind it.

Sibling folders:

- `docs/decisions.md` — system-level decisions (Postgres, Oban, monolith).
- `docs/.plans/` — feature implementation plans.
- `docs/discovery/` — customer / workflow research.
- This folder — UI architecture and design language.

## How this folder grows

One topic per file. When a topic is large enough that it has its own
"why" argument, give it its own document instead of burying it inside an
existing one.

Each file follows the same shape:

1. **What this is about** — one paragraph.
2. **Why it matters** — the product or user reality that forces the decision.
3. **Decision** — the prescription, stated plainly.
4. **Reasoning** — the argument that produced it.
5. **Alternatives considered** — what we rejected and why. This section is
   the most valuable part long-term; it prevents the same debates from
   recurring every quarter.
6. **Phasing** — implementation order, if the decision is buildable.
7. **What this does NOT decide** — explicit non-scope.
8. **Open questions** — known unresolved bits.

If a future decision overrides one of these, append a `## Superseded by`
note at the top of the old file rather than deleting it. The history of
why we changed our minds is worth keeping.

## Index

- [`philosophy.md`](./PHILOSOPHY.md) — the product design principles every
  screen answers to (lead with the money, compliance is invisible, propose then
  confirm…). Read first; the rest of this folder applies it.
- [`layout.md`](./layout.md) — application layout architecture: Ramp-style
  shell for system-of-record surfaces, Superhuman/Front-style list-detail
  cockpits for queue-shaped work, and how to choose between them.

## Planned (not written yet)

These are likely future entries. Add when the topic earns its own argument.

- Design tokens — color, typography, spacing, radius, shadow, motion timing.
- Component patterns — forms, tables, modals, toasts, empty/loading/error states.
- Density and responsive rules — when do tables collapse, when does the rail hide.
- Currency, date, and number formatting in the UI (₹ formatting already in place).
- Iconography — heroicons usage, when text beats icons.
- Mobile layout — not in scope today; document when it becomes one.

## Conventions

- **Reasoning first, prescription second.** If the reasoning is wrong, the
  prescription should be replaced. Bare prescriptions rot silently.
- **No em dashes in user-facing copy** (project memory). Hyphens or
  parentheses in design docs are fine.
- **Avoid emojis** in product UI and docs unless the user asks.
- **Show, don't only tell.** Diagrams (ASCII is fine) beat paragraphs for
  layout decisions.
