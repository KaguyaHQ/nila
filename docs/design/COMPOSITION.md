# Product composition

Read this before designing or substantially restructuring a product screen. Read
[`OPINIONS.md`](./OPINIONS.md) first. Opinions decide what exists; this document arranges
only what remains.

## Begin with the result

Write the promised user outcome in one sentence before drawing a screen.

Good:

> Put in the sales bills. Get a Tally sales register out.

Bad:

> Manage extraction, review, assurance, evidence, approval, and handoff.

The first sentence names completed work. The second exposes the system's decomposition of
that work.

The default surface should answer only:

1. What did Nila finish?
2. What can I use now?
3. What, exactly, remains?

If the job does not require one of those answers, do not manufacture a region for it.

## Every concept has a cost

A label asks the user to interpret a category. A state asks them to remember a distinction.
An action asks them to choose. A region asks them to scan. An interaction asks them to learn
behaviour. None is free merely because it is familiar UI.

Before adding any element, ask:

> If this disappears, can the user still obtain and understand the result?

If yes, remove it.

This test applies equally to headings, helper copy, badges, cards, tabs, filters, drawers,
tooltips, progress indicators, illustrations, animation, and “optional” details. Hidden
complexity still creates discovery and maintenance cost; keep it only when a real question
requires an answer.

Do not add structure for a possible future feature, a hypothetical persona, or because a
backend distinction exists. Product composition is not a diagram of the data model.

## Invariants

### One focal assertion

Every surface has one dominant assertion: the result, the unresolved remainder, or the
decision that cannot be automated. Rank what survives by consequence:

> result → remainder or consequence → unavoidable action → supporting context

Orientation is quiet. The work earns visual weight.

### Output plus exact remainder

Do not expose a taxonomy of partial completion when the user needs a usable artifact and
a remainder.

Prefer:

> 47 sales vouchers ready for Tally. 3 bills left out.

Avoid:

> 20 ready · 10 partially matched · 11 need checking · 1 unreadable

Richer states may exist internally. A visible state is justified only when it changes the
user's next unavoidable action.

### Uncertainty remains truthful

Simplicity must not create a false claim. Unresolved work cannot appear verified, approved,
reconciled, or complete. State the boundary plainly and once. Do not compensate for weak
assurance with panels of caveats.

### Empty regions do not render

No heading, card, tab, count, or placeholder exists merely to report that nothing exists.
Omit the region.

### The product does the work

An action belongs on the primary surface only when Nila can perform or complete it. Do not
turn unresolved work into task-management theatre. “Ask client for clearer copy” records
labour; it does not remove labour.

## Arrange only what survives

### Use one plane by default

A focused job begins on one plane. Add another only when the user must compare two things
simultaneously to make the unavoidable decision, such as a source document beside its
corrected entry. Empty width is not a reason to invent a rail.

### Use hierarchy before containers

Type, alignment, and space establish order before cards, borders, fills, or shadows. A
container exists only when it expresses a real boundary, selection, or floating layer.

### Draw only when drawing is faster

A visual relationship is justified when it makes an unavoidable comparison materially
faster to understand while retaining exact values. Do not visualize a number simply
because a component exists.

### Match density to the unavoidable decision

Registers may be compact because scanning is the work. Review may breathe because a human
must compare and decide. Density follows the job; it does not create extra supporting UI.

### Motion explains change

Motion may reveal or confirm a spatial change, then stops. Interactive delight is not an
independent requirement and cannot justify an interaction.

### Visual authorship comes last

Moonlight, typography, and an authored visual moment may make necessary work beautiful.
They may not introduce another concept, surface, or reading obligation. Beauty is the
feeling that the requirement has been satisfied with nothing left to remove.

## Product flow

The active job owns the screen. A finished job collapses to its result. The next job appears
only when it becomes the user's actual next action.

The GST month may provide context and history, but it is a shell—not the default work
surface. Workings, evidence, provenance, approval history, and statutory schedules remain
connected to the result and appear only when required for a real review, filing, or dispute.

Do not make a junior operate a workpaper to receive completed work.

## Completion test

Inspect the rendered desktop screen and ask:

- Can a new operator understand the value without instruction?
- Is the finished artifact more prominent than Nila's process?
- Does every visible state change what the user does next?
- Does every action remove or complete work?
- Is the exact remainder plain without becoming a taxonomy?
- Can any word, element, region, or interaction still be removed?

If the final answer is yes, the screen is not finished.
