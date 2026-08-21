# Marketing surfaces

Read this before changing `/`, contact, privacy, terms, data-deletion, or their shared
public shell. Read [`TASTE.md`](./TASTE.md) for aesthetic judgment and
[`FRONTEND.md`](./FRONTEND.md) for token mechanics.

The old ledger metaphor is dead. Public pages show the finished product as evidence and
say only what the evidence cannot explain itself. Moonlight styles that necessary content;
it does not require an additional visual moment.

## Sources of truth

- `lib/nila_web/controllers/page_html.ex` — `page_shell`, public header/footer, and legal
  page structure.
- `lib/nila_web/controllers/page_html/*.heex` — current public pages.
- `assets/css/app.css` — `.landing*`, `.moon-rise`, and all token values.
- `TASTE.md` — founder reactions, exemplars, and rejections.

Add a public page by composing inside `page_shell`; do not recreate the header, footer,
canvas, or bundle imports.

## Invariants

- Every section, sentence, artifact, and interaction must survive the deletion test in
  [`OPINIONS.md`](./OPINIONS.md). Marketing does not earn extra complexity because it is
  persuasive rather than operational.
- The product speaks, not the company. Show the finished artifact and what the reader
  gets; do not narrate Nila in the third person.
- Clarity outranks poetry. State the category or benefit only when the artifact and
  headline do not already make it inevitable.
- Brand appears once through the wordmark. Etymology and vernacular flourishes stay in
  design documentation.
- Every specimen number, time, sequence, and tax figure is a claim. Audit its arithmetic
  and implied timing.
- Marketing stays light overall. Midnight-sea may provide one necessary focal ground with
  visible luminance; never manufacture a section to display it.
- Motion reveals, then becomes still. No scattered perpetual animation.
- Use the same semantic moonlight tokens and shared controls as the product; public pages
  do not invent a second palette.

## Visual defaults

**Conceptual inevitability, expressed with delicate type and light.** The page should feel
arranged rather than generated: moonlight falling on a finished piece of accounting work.

- One focal figure or artifact per surface.
- Air is luxury; delicacy, not mass. Premium means precise, never zoomed-in.
- Serif is a human/display voice. Sans carries explanation and controls.
- Structure comes from composition, whitespace, faint fills, and subordinate ruling.
- The lone warm note appears once and for a reason.
- Evidence beats claims. A finished return state or review artifact explains Nila faster
  than another feature paragraph.
- Answer only the next question that prevents understanding or action. Anticipation is care
  only when it removes thought; speculative answers create it.

The landing-specific utilities in `app.css` are scoped to public pages and must not leak
into product markup:

- `.landing` scopes the public composition;
- `.landing-night` provides the authored midnight room;
- `.landing-moon`, `.landing-lift`, and `.landing-tile` support that composition;
- `.moon-rise` is the one finite reveal motion.

Exact implementation and values remain authoritative in CSS.

## Hero structure

Use the fewest layers that make the value unmistakable:

1. **Result** — preferably the finished product speaking for itself.
2. **Explanation** — one plain sentence only if the result cannot name the category or
   benefit unaided.
3. **Action** — only when the visitor has an actual next step.

Poetry is optional. Near-diegetic copy is preferred: “It’s done. Review.” Do not add a
poem, category sentence, or benefit merely to complete a template.

## Page composition

The public shell establishes orientation once. Each section then has one job and one
focal assertion. Avoid feature-card grids that repeat the same claim in different words.
A product specimen must remain legible and numerically credible, not become decorative
fake software.

Legal pages reuse `legal_page`; they are reading surfaces, not mini landing pages. Contact
and data-deletion pages use the same shell and type system without manufacturing a hero
when the visitor came to complete a task.

## Taste checks

Inspect the rendered desktop page and ask:

- Is the category clear without explaining the brand to itself?
- Does the product artifact do the selling?
- Can any sentence, section, visual moment, or interaction disappear without weakening
  understanding or action?
- Are the figures and times defensible to a skeptical CA?
- Is the page delicate, or merely sparse?
- After the reveal, does the page become still?

Marketing is not the product-system proving ground. The real client-month verification
surface remains the benchmark for whether moonlight helps an accountant reach conviction.
