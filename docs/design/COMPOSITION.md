# Product composition

Read this before designing or substantially restructuring a product screen. Do not load
it for a mechanical token or component fix; use [`FRONTEND.md`](./FRONTEND.md) instead.
[`TASTE.md`](./TASTE.md) judges the rendered result.

Tokens, size, spacing, radius, and motion are materials. Materials are not a screen. A
page can name every token correctly and still be a stack of boxes nobody wants to look
at. Composition decides whether the work is understandable and worth looking at.

The material has to be on the glass because looking is the task. A reviewer opens a
screen to reach conviction: the month ties, nothing is missing, and the figure is safe
to sign. The signature is the last gesture, not the purpose. Whatever establishes that
conviction belongs where the eye reaches it without a discovery click.

## Invariants

### One focal assertion per surface

Every page, card, and panel has one dominant assertion or relationship. It is the thing
the reader came to verify: a figure, a pair that must agree, a residual, a document, or
a decision. Rank by consequence, never by element type:

> assertion or relationship → consequence or residual → labels

On a wide verification workbench, the page title is chrome. Spending the largest type
on `Breeze Tech · May 2026` while the figures being signed sit beneath it in ordinary
copy inverts the screen. Keep orientation quiet and let the work earn visual weight.
Two values that must agree are one focal relationship, not two competing cards.

### Uncertainty stays visible

Fold verified support; never fold unresolved work. Machine findings, human decisions,
approval, and filing state remain visually and semantically distinct. An unresolved
item does not disappear into a summary, and a derived equality does not become a
passing independent control.

### Empty regions do not render

A heading over an absence spends a labelled region explaining that nothing exists.
If a section has nothing to show, omit it and let the one line that owns state carry the
absence.

The full anti-pattern:

> **SIGNATURES AND FILING**<br>
> GSTR-1 signature waits: the GSTR-1 still has issues to check

## Defaults

### Show the shape, not only the sentence

A screen where every element is prose has no glance state. Draw a relationship when its
shape is faster to verify than aligned figures alone, but retain exact values and the
assertion in accessible text.

| Relationship | Visual form | Exact reading retained |
| --- | --- | --- |
| Coverage — how much of a whole is settled | Filled mass against remainder | “247 of 252 purchase lines matched” |
| A pair that must agree — books vs 2B | Adjacent figures with residual between | Both figures and the residual |
| A run that must be unbroken | Sequence with gaps made visible | Range and named gaps |
| Parts of a total | Proportion only when it clarifies consequence | Every aligned amount |

A repeated domain relationship deserves a first-class component under
`lib/nila_web/components/`. Do not ship a sentence merely because no visual primitive
existed. Visual encoding supplements precision; it never replaces it.

### Fold summaries are assertions, not inventories

A closed fold claims the reader need not inspect its contents. The summary must say what
supports that claim:

- **Tie-out** — independently derived values agree; show both and the residual.
- **Derived identity** — one artifact was produced from another. This is provenance,
  not corroboration.
- **Coverage** — state what population and value are settled while unresolved rows stay
  outside the fold.
- **Inventory** — “2 parties · 1 rate · 3 HSN codes” only describes contents. It does
  not by itself justify hiding them.

A fold may also be an explicit inspection affordance for appendix-grade schedules. In
that case say what the schedule contains and never imply verification it does not have.
The primary workflow remains outside it.

### More than one plane

A wide verification workbench should use more than one density when supporting state
exists: the material being verified and a quieter rail or margin carrying deadline,
provenance, or consequence. A single centred column on a wide canvas can make unused
width read as abandonment. Air is space between things; space after the last thing is
only empty.

Do not invent a second plane for focused forms, authentication, upload, or constrained
screens that have no supporting state.

### Match density to the decision

Canvas density and element density are different. A CA workbench can place substantial
material on one screen while keeping each relationship clear. Queue rows and working
sheets are compact and glanceable. Review, correction, and signing surfaces use more
space because a human is making an accountable decision.

Detailed schedules are proof beneath the prepared outcome. They remain available and
source-linked, but do not dominate the operating experience by default.

### Rhythm and air

Use larger separation when the reader moves between different questions and smaller
separation inside one thought. Vary rhythm: four regions at an identical gap become a
list and communicate no hierarchy. The executable spacing scale lives in `app.css` and
its application rules in [`FRONTEND.md`](./FRONTEND.md).

### One authored moment

Persistent chrome may carry one quiet brand ground, such as the midnight-sea rail
framing Nila’s pale workspace. A screen may add one page-specific element that is drawn
rather than assembled—a luminous ground, a bespoke relationship, a carefully authored
mark—and it belongs to the work the screen is about.

This is a strong default, not an invariant. Break it only when the rendered composition
has a concrete reason, not because another decorative surface looked attractive.

## Workpaper composition

A client-month surface leads with the prepared result, the real blocker, and one
state-aware primary action. Exactly one complete workpaper is visible at a time. Compact
section navigation answers “where is the evidence?” while the primary action answers
“what do I do next?”

The usual order is:

1. prepared outcome and current next action;
2. required human review or recorded resolution;
3. compact control assertions;
4. operational register;
5. return workings and supporting schedules;
6. source evidence and attributed history;
7. approval and downstream handoff.

This is a hierarchy, not a requirement to manufacture empty sections. Purchases and
GSTR-3B use the same outcome-first logic with their own truthful lifecycle; do not invent
approval or completeness semantics merely to make tracks symmetrical.

## Taste checks

These cannot be linted. Inspect the rendered desktop screen.

- Does the eye land on the work rather than the page chrome?
- Is there a glance state, or must every sentence be read?
- Is supporting material subordinate without becoming hidden or microscopic?
- Does the amount of air match the consequence of the decision?
- Are borders doing quiet structural work rather than assembling a dashboard template?
- Is the one authored moment about the product relationship rather than decoration?
- Would a skeptical CA understand what was checked, what was decided, and what remains?

The real client-month verification surface is the proving ground. Beauty there means
conviction is available on the glass without a discovery click.
