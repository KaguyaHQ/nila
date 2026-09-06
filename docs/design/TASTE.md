# Current design taste

Current accepted direction, 2026-09-06. This file owns aesthetic preferences, not token
values or product scope. Historical experiments are in [the archive](archive/README.md)
and do not add requirements to this specification.

## Precision that feels alive

Use crisp, light surfaces and disciplined alignment, then guide the eye with selective
weight, small meaningful colour accents and softly shaped controls. The beauty comes
from their combination. Preserve useful density and consistent roles across pages;
avoid both heavy chrome and lifeless minimalism.

The populated June GST table is the concrete reference: **stronger populated labels +
green Prepared marks + unbroken counts + soft export buttons**. The green marks drew
the strongest reaction, but Vasanth explicitly clarified that the typography and other
refinements made the whole table pleasing. Reproduce that coordinated hierarchy, not
an isolated green decoration.


Vasanth prefers light navigation, white panels and a quiet canvas with sharp readable
text. Selective colour and emphasis make restraint feel alive. Dark chrome, large empty
areas, low contrast or excessive badges do not automatically make software premium.

Origin's **light** application screenshots are the reference. Adapt their proportions,
alignment and clarity to accounting density; do not copy charts, promotional panels,
gradients or decorative controls. The populated June GST workspace, banking list and
Clients directory are the accepted local examples, with task-specific compositions.

## What worked

- Soft blue secondary export buttons feel cohesive and approachable. Keep a distinct
  primary action; do not make every control blue or every secondary action identical.
- Modestly stronger populated schedule names and small green Prepared indicators give
  the eye useful destinations. Readable empty rows retain orientation without grey pills.
- Consistent page identity, panel alignment and control proportions make different pages
  feel like one product. A sparse page does not earn a larger title.
- Counts kept together, aligned figures, natural filename truncation and correct singular
  labels matter. Small flaws can make otherwise good software feel unfinished.
- Borders are quiet structure. White space supports relationships and scanning; neither
  maximum air nor maximum density is the objective.
- Sans-serif carries operational work. Serif is reserved for earned human/display moments.
  Rounded controls remain precise, not oversized or excessively soft.

## Strong preference signal — the June table refinement (2026-09-06)

On the populated June GST table, Vasanth singled out the tiny rounded green marks beside
Prepared: “I specifically LOVE the little green thing,” “the table looks so pleasing,”
and “instantly 10 times better.” This was a strong emotional response to a small detail,
not a request for more colour everywhere. He subsequently singled out the stronger
populated-row typography too: “you also made other changes in the table like bolding?
it's so nice.”

Design interpretation: small, soft, meaningful accents within precise aligned structure
make the restrained UI feel alive. Preserve this reference when refining tables. Repeat
accents selectively where they help scanning, retain the text meaning, and do not inflate
them into badges or use green for unresolved work. This interpretation is a working
hypothesis about his taste; the quoted reaction is the direct evidence.

## What to avoid

Lifeless monochrome, heavy enterprise chrome, washed-out required text, giant headings,
repeated status pills, arbitrary card grids and decoration added to fill space. Do not
mistake removing visual weight for improving hierarchy.

The historical claims “almost no borders,” “half the content density” and a mandatory
dark moment are superseded for product UI. Marketing has its own scoped direction in
[MARKETING.md](MARKETING.md); its artwork does not define workbench styling.

## Judge the rendered result

Can the eye find the useful result and action immediately? Are populated and empty states
distinguishable without clutter? Does the page feel precise and calm at actual scale?
Do equivalent roles match neighbouring pages? Does colour help rather than compete?

Refine the current necessary content before proposing more content. Record durable user
preferences here; put implementation rules in FRONTEND and layout decisions in COMPOSITION.
