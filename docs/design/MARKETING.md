# Marketing surfaces

Owns public-page composition for `/`, contact, privacy, terms and data deletion.
Use [DESIGN.md](DESIGN.md) for invariants and validation, [OPINIONS.md](OPINIONS.md) for
scope, [FRONTEND.md](FRONTEND.md) for mechanics and [TASTE.md](TASTE.md) for current taste.

## Public voice

Show the finished product as evidence; say only what the artifact cannot explain.
Speak to the visitor's result rather than narrating the company or its architecture.
Clarity outranks poetry. Brand appears once in the shell; etymology and self-admiring
flourishes do not belong in a hero. Audit every specimen number and implied processing
time as a real claim.

The fewest hero layers are: **result → explanation if needed → actual next action**.
Do not add a poem, category sentence or benefit merely to complete a template.
Prefer concrete copy such as “It's done. Review.” over vague promises.

## Visual direction

Light overall, with delicate type, subordinate ruling and one focal artifact per section.
Serif may carry human/display moments; sans carries explanations and controls. Moonlight
artwork may style necessary content but cannot justify another section. A midnight-sea
focal ground is permitted here when useful; it is not a product sidebar theme.

Avoid repetitive feature-card grids, fake unreadable software and generic glossy decoration.
Anticipate only the next question that prevents action. Motion may reveal the composition,
then becomes still. Marketing is not the proving ground for workbench defaults.

## Implementation boundaries

- `lib/nila_web/controllers/page_html.ex` owns `page_shell` and public chrome;
  `lib/nila_web/controllers/page_html/*.heex` owns page bodies.
- Reuse the public shell. Legal pages use `legal_page` as a reading surface; contact and
  data-deletion pages do not need a manufactured hero.
- `assets/css/app.css` owns artwork and tokens. `.landing`, `.landing-night`,
  `.landing-moon`, `.landing-lift`, `.landing-tile` and `.moon-rise` are scoped public
  utilities, not reusable product surfaces. FRONTEND lists permitted brand exceptions.
- Use shared controls and bundles. Do not introduce another palette or external assets
  through script/stylesheet tags.

During the DESIGN completion loop, check that the category is clear, the artifact does
the selling, figures are credible, and the page feels deliberately arranged rather than
merely sparse. Keep the real accounting surface as the evidence of product quality.
