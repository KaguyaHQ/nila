# Chiller renewal session — what cleaning the rate-list revealed

Evergreen discovery from a real working session (2026-06-16/17): the owner and
his son sat together and audited the Siemens chiller LAMC renewal lists for
FY 2026-27 across six states (TN1, TN2, KL, KR, TL, AP), with an AI agent doing
the row-by-row checking. This is the *renewal* counterpart to the quoting study
in [`quotation-workflow.md`](./quotation-workflow.md) and the receivables study
in [`customer-workflows.md`](./customer-workflows.md) — same business, the
recurring-AMC back end.

Source artifacts: the per-state `*.xlsx` rate lists (e.g. `TN1 April 2026 -
March 2027 AC Chiller List.xlsx`) and the rate contract itself (`Imported
Chiller LAMC Prices` — a one-page PDF, page 3 of 6). Nothing here is
hand-transcribed; the numbers are from the files.

## 1. What the artifact is

One workbook per state. The live tab (` Renewals FY 25-26` in TN1) is **one row
per installed Siemens machine**: `EID` (Siemens equipment id) + serial + site +
customer + model (`MAGNETOM Sempra`, `Essenza`, `Amira`…) + RC category
(`ESSENZA CHILLER`, `Ext MRI Chiller`, `WCS`…) + contract type (LAMC) + a
14-column year grid (`2013-14 … 2026-27`) of escalated prices. ~100 rows per
state, ~993 across six.

It is an **asset register wearing a price-grid costume.** The rows are installed
machines that persist year to year; the year columns are not data, they are a
*derivation* off the rate contract.

## 2. The rate contract (the keystone — 20 numbers)

The whole price model is one page: **5 categories × 2 zones × 2 cards.**

- Categories: Affinity, Ext MRI Chiller, Essenza, WCS, WCS Dual.
- Zones: Local (Chennai within 60 km) / Outstation.
- Cards: **old** (units under contract since 2013) and **new** (units added
  2025-26, priced off the 2022-23 base — explicitly: *"any new chiller units to
  be included in contract for 2025-26 will be considered from the base price of
  2022 to 2023"*).

Old-card outstation rates (FY 26-27 region): Essenza 28,474 · Ext MRI 34,170 ·
WCS 22,781 · WCS Dual 29,898 · Affinity 27,050. New-card outstation: Essenza
27,103 · Ext MRI 32,524 · WCS 21,683 · WCS Dual 28,459 · Affinity 25,748.

Every one of the 993 rows *should* snap to one of these 20 cells. Every bug
below is a row that didn't.

## 3. What the audit found (raw)

- **Free-serviced machines — the revenue leak.** TN1 had 3 rows that turned out
  to be machines they *stopped* servicing years ago but were still carried
  forward (EID 1033805611 Priya Diag ×2; EID 1050167476 Sri Chakra/Kolathur).
  In practice these had been serviced without a paying contract — silent
  recurring loss. They were only caught because the clean roster got diffed
  against reality.
- **Price drift / miscategorisation (per state):**
  - AP — 18 of 50 rows wrong (36%). 16 Essenza units stamped at the Ext MRI
    rate (34,170 vs 28,474, +5,696 each ≈ 91k); 2 on the 29,898 default.
  - KL — 16 new units priced on the old card; 1 WCS bumped to WCS-Dual rate
    (+7,117); 7 legacy Ext MRI never snapped to the card.
  - KR — 4 rows on the 29,898 default; 6 rows hidden under bogus labels
    (`Rideal`/`KKT` — actually Free.Star/Sola/Vida).
  - TN2 — 1 zero-price; 3 Affinity on the 29,898 default.
  - TL — clean.
- **The cross-file root cause:** a draft formula defaulting any category that
  isn't Essenza or Ext MRI to **29,898** (the WCS-Dual rate), catching Affinity
  and plain WCS across TN2/KL/KR/AP.
- **Label inconsistency across files:** the same machine (Sola, Vida) classed as
  `Essenza` in one state and `KKT/Ext MRI` in another — 5,696 swing per row.
- **Duplicate EIDs in the source:** same physical machine listed twice under
  two customer-name variants (TN1 1033805611, 1050167476; TN2 1038735545,
  1063484572).

## 4. Why it happened (the owner's account)

The owner had **not sat down to do this for years** — not because it was hard,
because it was *painful*: 4-5 hours of manual cross-checking nobody would do.
This year it took one session only because the checking was delegated to an AI.

The free-serviced machines were missed because of **knowledge fragmentation**:
the fact "we stopped servicing these" lived only in the owner's head. The staff
who carry rows forward (copying last year's sheet into this year's, across the
`Hold for 2024 / 2023 / 2022` tabs) don't have that knowledge, and nothing in
the sheet records it — so the machine kept getting copied forward and serviced.
Truth stored in a person + copy-across-tabs = silent persistence of the wrong
state.

## 5. The four value terms, evidenced

This one session hit all four value terms from `strategy.md` §1 with real
incidents:

- **Labor arbitrage** — 5 hours → minutes.
- **Error elimination** — the 18 AP rows, the 29,898 class, prevented *by
  construction* if price is derived from the card, not typed.
- **Visibility** — the owner could finally see the state of his own renewals.
- **Bus-factor / institutional knowledge** — the free-serviced machines: truth
  moved out of the owner's head into a roster anyone can query.

## 6. Open questions

- **New-vs-old card is the one human call.** The sheet cannot mechanically decide
  whether a unit is on the old or new card (this session: "assume all old").
  That judgement is the `needs_review` boundary in real data.
- Why exactly the three TN1 machines went out of contract (forgot to renew /
  no PO / quote sent at zero) — answer drives which guardrail matters most.
- Whether Sola/Vida is Essenza or Ext MRI (cross-file label conflict, unresolved).
