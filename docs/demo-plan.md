# Demo Plan: The Finished Month Pack

Goal: produce the month pack for a family entity — dump → draft → review, graded against
the actually-filed returns — as files that run off a laptop with no server. This is a
performance staged on real data, not a product build.

## Locked decisions (from the grill — do not relitigate silently)

- **Demo a finished month, not software.** No new UI surfaces. The pack is files:
  Excel, PDF (Typst), JSON, MP4. Deliberately un-slick — "best junior he ever had."
- **Scripts orchestrate, `lib/` owns logic.** Zero business logic in `.exs` files.
  Every matching rule, flag, threshold lives in pure modules under `lib/nila/`, same
  discipline as `Nila.Gst` / the GSTR-1 harness. Scripts are IO shells.
- **Flag-don't-guess.** The matcher never emits a wrong *confident* match. Principled
  rules only (GSTIN, invoice number, value tolerance, explicit fuzzy-name logic) — no
  vendor-specific patches. Everything below the confidence line routes to the
  confession sheet with a reason. Falsifiable invariant: a wrong confident match on
  foreign data means the engine was built wrong.
- **Traces-not-verdicts.** Every diff/mismatch is presented as "two differences, here's
  the trace to source documents, you decide." Never "your office got this wrong."
  Peer-firm data in other meetings: anonymized, same rule.
- **No synthesized eligibility number.** ITC page shows exactly three things:
  mechanical 2B-matched total, sharp flagged-lines list (reason + section ref + source
  link), annotated diff vs filed 3B with a trace per gap. No "eligible ITC" figure, no
  band. Confident detection, confessed judgment.
- **Seeded catches must reproduce live.** Every flag in the demo is a catch the system
  makes on the real data under a partner's poke. Staged frequency fine; faked
  capability never.
- **Checklist footage is hand-staged outbound, real inbound.** Outbound messages typed
  manually from WhatsApp Business (the trivial leg); dad's replies + photo land through
  the real ingest worker against the right row (the doubted leg). Narration matches
  reality; direct question gets the straight answer ("send automation is pilot-setup
  paperwork; the reply capture you just watched is the hard part, and it's built").
- **Confession sheet ("what we couldn't do")** is load-bearing: the demo's most
  persuasive page and the technical hedge for the retro run.
- **Winman sheet: placeholder** until a real template is in hand. A guessed format
  reads as fake competence.
- **Firm workings = enhancement, never critical path.** One ghost-proofed ask (dad
  requests his own client records, direct channel, no product explanation), five-day
  time-box, zero chasing. Workings arrive → purchase diff upgrades to line-level.
  Ghost → pack ships anyway on the 3B aggregate diff.
- **All months, both entities** (Breeze + Caltech) in fixtures; hero month chosen
  late — it's a reversible decision. Hero needs the full triangle: purchase bills +
  sales bills + filed GSTR-1 + portal GSTR-2B + filed 3B for one month.
- **Cut order** if the matcher eats extra days: built surfaces behind the checklist
  footage, then second-entity/extra-month reruns. The footage itself never gets cut
  (near-zero cost, closed-loop claim). Winman is already a placeholder.

## On-disk assets (verified, reuse — don't rebuild)

- `scripts/gstr1_eval_lib.exs` + `eval_gstr1.exs` + `extract_sales.exs` — the whole
  extract → derive → diff-against-filed → corrections → silent-errors pattern. The
  purchase side mirrors this shape.
- `Nila.Gstin` — full checksum validation. `Nila.Fuzzy` — normalize/match_score/
  best_score for the name leg. `Nila.Gst` — jurisdiction/tax-split math.
  `Nila.Typst.render/2` — printable pack. `Nila.LineKind`, `Nila.Gst.StateCodes`,
  `Nila.Gst.PlaceOfSupply`.
- `Nila.Integrations.Whatsapp` — **inbound only** (`normalize/2`, `fetch_media/2`).
  Outbound does not exist; per Q8 it is deliberately not built for the demo.
- Fixtures: sales PDFs for Breeze (Jan, May) + Caltech (Oct–Jan) in
  `~/Documents/data/demo/sales`; Breeze October purchase PDF (57pp merged scan) in
  `~/Documents/data/demo/purchase`; gstr1 filed fixtures + holdouts in test tree.

## Track P — data procurement (parallel to all stages, human-driven)

- P1. Drop remaining purchase PDFs, all months, both entities, into `data/demo/purchase`.
- P2. Portal pulls (access confirmed): GSTR-2B JSON, filed GSTR-1 JSON, filed 3B for
  every month, both GSTINs. **2B for at least one month is needed before Stage 2 ends** —
  earliest external dependency, do it day 1.
- P3. Sales PDFs for months not yet on disk (Breeze Oct–Dec etc.).
- P4. Dad's one-shot workings ask ("Send me Breezetech's GST workings for May and June,
  for my records"). Five days, no chase, no product mention.
- P5. Real WhatsApp thread screenshots / original loose bills if they exist — the
  intake "before" beat. If the mess only exists as merged scans, show that honestly.

## Stages (each ends demoable; matcher first — it's the long pole)

### Stage 0 — purchase intake spine (~half day)
- `scripts/extract_purchases.exs` mirroring `extract_sales.exs`: LlamaExtract per-page
  with a purchase-invoice schema (vendor name, vendor GSTIN, invoice no, date, line
  items, HSN, taxable value, tax split, delivery address). Per-page JSON artifacts.
- PDF → per-page images (`pdftoppm`/`mutool` via script) into `images/`, named to
  match page artifacts. This is the evidence spine.
- **Verify the one-bill-per-page assumption** on the October PDF. Multi-page bills
  break the page↔invoice mapping; if found, add a page-grouping step before anything
  downstream depends on the mapping.
- Done when: October Breeze purchases exist as per-page artifacts + linked images.

### Stage 1 — the 2B matcher (days 1–3, the risk item)
- `lib/nila/gst/recon.ex` (pure; takes plain maps, returns plain maps — same
  testability posture as `Nila.Gst`). Match keys, in order of strength: vendor GSTIN
  (exact, post-checksum), invoice number (normalized: case, leading zeros, separators,
  common prefixes), date proximity, value tolerance in paise, fuzzy vendor name via
  `Nila.Fuzzy` as explicit last-leg logic.
- Output buckets: `matched`, `value_mismatch`, `in_books_not_2b`, `in_2b_not_books`,
  and `needs_human` (below confidence line, with machine-readable reason). Every
  non-matched bucket row carries reason + drafted next action (vendor chaser text /
  client checklist item).
- `scripts/eval_recon.exs` + fixtures: grade the matcher on real October data (real 2B
  from P2). Test the poke cases explicitly: name off by one letter, transposed invoice
  digits, ₹1 value drift, same vendor two invoices same value.
- Done when: October recon buckets are correct under manual audit and the
  wrong-confident-match count is zero.

### Stage 2 — validation flags + confession sheet (~1 day)
- `lib/nila/gst/flags.ex` (pure): GSTIN checksum fail (reuse `Nila.Gstin`),
  vendor-name-vs-GSTIN mismatch (reuse `Nila.Fuzzy`), HSN plausibility vs business
  type, personal-expense / 17(5) candidates (the fridge: consumer-goods category +
  residential delivery address), each flag = {line, reason, section ref, confidence,
  source link}. Sharp and specific — "₹42,000 Croma invoice, delivery address
  residential, likely 17(5)(g)" — detection confident, judgment confessed.
- Confession sheet generator: every `needs_human` recon row + every below-line flag,
  with "could not classify — routed to human, here's why."
- Done when: each demo catch appears at least once on real data and reproduces on
  re-run.

### Stage 3 — the register (~1 day, hard time-box)
- Purchase + sales registers as Excel with `HYPERLINK()` cells → `images/` (relative
  paths only; `register.xlsx` at zip root, `images/` sibling). Columns: the boring
  junior-register shape + flags column + recon bucket.
- **New dep decision (do not add silently): an xlsx writer (`elixlsx` or equivalent).
  Verify it emits formula cells before committing; if xlsx-formula support fights past
  the time-box, the fallback is NOT HTML — it's the Typst paper pack with inline
  evidence appendix (Stage 5), which ships regardless.**
- Test on Windows Excel (CA offices run Windows; dev machine doesn't). Ship as zip
  that opens off a USB stick.
- Done when: click a flagged line on a Windows machine → source invoice image opens.

### Stage 4 — the graded diffs (~1 day)
- Sales spine: rerun the existing GSTR-1 eval for the hero month; format the diff as a
  pack page ("system output vs filed return: X matched, these exceptions, here's why").
- Purchase spine: 3B ITC annotated diff — mechanical 2B-matched total vs filed 3B ITC
  figure, every gap traced to a source document/flag. No synthesized number anywhere.
- Evidence self-audit page: every register line has a source image; count and confess
  any that don't.
- If P4 lands: upgrade purchase diff to line-level against the firm's workings.
- Done when: the pack contains at least one page that says *verified*, not *claimed*.

### Stage 5 — pack assembly (~1 day)
- Typst pack via `Nila.Typst`: cover/status list ("these still missing X, everyone
  else done"), intake "before" page (honest — P5 material or the 57-page scan dump),
  register summaries, recon buckets with next actions, flags pages, confession sheet,
  graded diff pages, **inline evidence appendix** (flagged line → source invoice image
  as the following page — provenance with zero clicks, works on paper), Winman
  placeholder tab, validated GSTR-1 JSON on the stick.
- Boring, Excel-shaped, printable. No design flourishes.
- Done when: the printed pack reads end-to-end without a laptop.

### Stage 6 — checklist footage (one evening, never cut)
- Stage the exchange per Q8: manual outbound from WhatsApp Business; dad's real yes/no
  taps + photo of a missing bill; inbound leg through `whatsapp_ingest_worker`, photo
  binding to the exact orphan-2B row. Screen-record both phone and the row updating.
  MP4 goes in the pack. App exits the demo after this — nothing live in the meeting.

### Stage 7 — dress rehearsal (~1 day)
- Full re-run from raw PDFs on a clean checkout: one command chain → pack out.
- Poke-test as the partner would: perturb a vendor name, an invoice number, a value;
  confirm flags fire and no confident mismatch appears.
- Re-run a second month/entity end-to-end to prove repeatability (first thing cut if
  Stage 1 overran).

## Deferred with a home — pilot-prep checklist (not demo work)

- Meta WhatsApp template approval + outbound send (the chase scheduler's mouth).
- Chase state machine (Oban: remind day 3, escalate day 6, state update on reply) —
  the app's first real surface, at first live pilot month, not before.
- Re-skin pack to the firm's own workings/Winman template once a real one is in hand.
- Retro-run delivery = drop firm's client docs into fixtures, re-run this harness,
  regenerate pack in their skin. The scripts are the pilot workflow.
