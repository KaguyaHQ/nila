# TASTE.md — Vasanth's design taste, on the record

What the founder actually responds to, extracted example by example. DESIGN.md
is the rulebook; this is the taste that judges it. When the two disagree, this
file explains what the rulebook should become. Append new entries with a date;
don't rewrite history.

## 2026-07-31 — the /landing grill

### The one-line taste

**Delicate type in large space, anticipated intent, one authored moment of
light.** Beauty = a painting: light falling on an arranged scene — moonlight on
a finished ledger. Vermeer, not a template: the most ordinary artifact in a
CA's life made stare-at-able by how it's lit and placed.

### Exemplars (what "damn" looks like)

- **Origin (dashboard + connect modal)** — the benchmark. Why it works:
  - **One focal figure per surface.** One big number per card; everything else
    drops to whisper-weight tracked-out micro-labels. The eye always knows
    where to land, and can wander the page "like a painting."
  - **Almost no borders.** Structure from whitespace and faint fills, not
    hairlines around everything.
  - **Serif only for human moments** ("Your weekly recap") — so it reads as a
    voice, not a font. Working UI stays sans.
  - **Air as luxury.** Half the content density we'd instinctively ship.
  - **Delicacy, not mass.** Small precise type floating in big space — a jewel
    on velvet. Premium = *fine*, never *large*.
  - **Anticipation = care.** The connect modal pre-answers your next three
    moves (search / popular tiles / categories). "They thought of what the
    user wants" is the felt experience of care.
  - Contains exactly **one dark moment** (the midnight tax card) in a light
    page — and the eye goes there first.
- **Agent-demo landing page** (video of an agent clicking through a page) —
  comprehension in an instant, zero reading cost. **Show, don't tell: evidence
  over claims.** (Its playful font was wrong for us — mechanism yes, register
  no.)
- **Gamma's hero** — "colorful, interesting, artistic." What's actually loved:
  **authorship**. A real aesthetic decision someone stood behind — a luminous
  night sky. (Their inner pages, same palette, are rejected: production, not
  art.)

### Rejections (what "no" looks like)

- **Density / evidence-piling** (our old ledger homepage): "you are being
  pathetic if you have to beg the CA to stay." Confidence = proof stated once,
  beautifully, without pleading.
- **Neutral black / charcoal** (Midday, Grok): "nothing. black. blunt.
  emotionless." Dark is only allowed as **midnight-sea with visible
  luminance** — night with a moon in it. Nila never touches achromatic black.
- **Gargantuan type** (Ramp's product): "200% zoomed in. i'm not blind." Big
  rows and big fonts read as "big picture mode," the opposite of refinement.
  (A big serif hero is acceptable on marketing only; never in product.)
- **Glossy generated decoration** (Gamma inner pages, Airbnb 3D icons):
  production without authorship. The detector fires on *intent*, not color
  count.
- **Enterprise layout by committee** (Synthesia): "where is the beauty." The
  ideal instead: a calm beautiful opening that just says *look* — "it doesn't
  say much. you are pulled along by the intent."

### Standing decisions

1. **Ledger metaphor is dead** for the new style. Marketing becomes moonlight.
2. **Light room, one night moment.** Pale luminous page; the hero may open in
   authored moonlight (deep midnight-sea gradient, soft lunar glow) resolving
   into light. Never a dark site.
3. **The product speaks, not the company.** Hero = the finished artifact
   ("Ready for review · 6:04 AM", five exceptions), near-diegetic copy. Door-
   to-door does the selling; the page's only KPI is *damn*.
4. **Reveal, then stillness.** At most one quiet settle on load; afterwards the
   page is a painting. No scattered motion.
5. **Delicacy rules:** one focal figure per surface; air above the current
   32px ceiling; borders near-zero; ink pulled toward neutral so blue is
   reserved for meaning; sand accent appears once.
6. **/landing is the moonlight-v2 proving ground.** If it produces *damn*, the
   deltas are written back into DESIGN.md and the product inherits them.

### Addendum, same day — first critique of the built page

- **Clarity outranks poetry.** Origin's hero is the model: the poem ("Own your
  wealth."), then one plain line naming the category, then second-person
  benefits. A poetic headline alone leaves "what the hell is this product"
  unanswered. Every hero needs all three layers.
- **Don't narrate in the third person.** "Nila finishes your months" as the
  only explanation reads like "Apple makes delightful products." Name the
  category once, then speak to the reader: what *you* get, what *you* do.
- **No self-indulgent brand flourishes.** "Nila · நிலா" as a hero eyebrow was
  cut — the brand appears once (the wordmark) and the page moves on. Etymology
  belongs in the design doc, not on the customer's screen.
- **No self-indulgent brand flourishes.** The "Nila · நிலா" hero eyebrow was
  cut: the vernacular script read as the brand admiring itself, not as care
  for the reader. Heritage lives in the name and the moon; it doesn't need a
  caption. (Same test as decoration: does the reader gain anything?)
- **Numbers on a page are claims and get audited.** A timeline of clock times
  (11:48 PM → 6:04 AM) read as "processing takes seven hours." Any specimen
  figure, time, or sequence must survive a skeptical CA's arithmetic — or say
  the fast thing explicitly ("reconciled within the hour").

### Diagnosis of the current system (why our pages feel "okay, I'll work")

Both the doc and the implementation, but DESIGN.md carries blame on four
counts: it **mandates borders around everything**; **every word is tinted
blue** so nothing is; the **spacing ceiling (32px) outlaws Origin-level air**;
and it is **a rulebook of bans with no composition theory** — nothing says
"one focal figure per surface," so a page can obey every rule and stay flat.

## 2026-07-31 — Origin reference corrected

The earlier entry misremembered the benchmark. Origin uses hairlines around
most major cards; they succeed because they stay subordinate to composition,
not because they are absent. Origin is also dense at the canvas level. Its
restraint is per element — delicate type, clear hierarchy, and air inside and
between subjects — not "half the content."

The proving ground is the real client-month verification surface, not
`/landing`. A CA opens it to verify reconciliations and workings before signing;
the product succeeds when that conviction is available on the glass without a
discovery click.
