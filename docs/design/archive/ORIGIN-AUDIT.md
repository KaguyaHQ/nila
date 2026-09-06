# Origin comparison and Nila consistency audit

Date: 2026-09-06. Original audit findings are preserved below as historical evidence.
The implementation section records the subsequent consistency pass; this is not a
claim that every product route has received a visual audit.

## Evidence

The agent inspected all four screenshots in `C:/Users/benze/Pictures/Origin`:
`Screenshot 2026-09-06 104749.png`, `104832.png`, `104914.png`, and `122736.png`.
They show Transactions, Reports, Monthly Budget, and Estate Planning. Screenshot
measurements establish relative visual hierarchy, not exact source CSS or ultrawide rules.
Root independently inspected shared components and measured rendered headings with Playwright.

| Page at time of audit | Typeface | Size / weight | Line height |
| --- | --- | --- | --- |
| Clients | Switzer | 40px / 400 | 42px |
| Banking list | Switzer | 20px / 500 | 27px |
| GST overview month | Switzer | 20px / 600 | 27px |
| Add client | Newsreader | 48px / 400 | 50.4px |
| Bank upload | Newsreader | 48px / 400 | 50.4px |

## Root cause at time of audit

The new visual direction was applied page by page while shared headers and table
recipes retained the old direction. Allowed tokens alone do not enforce role consistency.
Documentation was updated before the shared primitives were aligned.

## What Origin repeats

Page identity stays stable across Spending subpages. Page titles, panel labels,
table headings, and content headings are distinct roles. Table labels are regular
sentence case; small tracked uppercase panel labels are a separate role. White
panels, quiet canvas, fine borders and neutral navigation repeat. Color identifies
categories, data and warnings. Content composition varies with the task.

## Original priority corrections

1. Establish one operational page-title and header recipe. Current hand-coded
   headings diverge across `clients_live.ex`, `banking/upload_live.ex`, and
   `components/gst/month/sales_workspace.ex`. `components/page.ex` still renders
   operational forms with a large serif display header. A 28px/500 title is a
   proposed Nila choice to test together, not an extracted Origin measurement.
2. Change shared `components/table.ex` schema headers to regular sentence case;
   remove the repeated local slot overrides. Preserve acronyms such as GSTIN.
3. Reuse the same GST period header in overview and detail. Today context case,
   font weight, arrow size and deadline placement change on drill-down.
4. Standardize page top spacing and header-to-content rhythm. Clients has extra
   top padding and a different gap; the other pages assemble their own rhythm.
5. Define panel header/body alignment using shared recipes. Account for table
   cell padding instead of applying equal wrapper padding blindly.
6. Place actions by scope: page creation near page identity, workflow action near
   the result. Remove explanatory strips that do not convey useful information.
7. Allow banking filenames to use their actual identity-column width instead of
   truncating at a fixed `max-w-sm` while leaving unused space.

## Differences worth retaining

Clients can be a narrow directory; GST and Banking can use the wider 1400px cap;
forms and document review have other spatial needs. Name these layout roles rather
than imposing one width everywhere. Retain scan/worklist density roles. Keep every
GST schedule visible in a stable order, with readable quiet empty states. Do not
add charts, colorful decoration, or content merely to resemble populated references.

## Implementation and documentation alignment

The shared `<.page_header>` now owns operational page identity through `text-page`
(28px/500 sans-serif), with page actions and a title-actions slot for period navigation.
This is a Nila role choice, not a measurement extracted from Origin. The shared table
default now uses regular-weight schema labels without uppercase transformation, preserving
acronyms and interactive header slots. Consumers should use plain labels instead of
duplicating typography overrides.

DESIGN, FRONTEND and COMPOSITION now distinguish page, section and display typography;
define directory/workspace/form width roles; and explicitly retain the full GST schedule
index. TASTE records the accepted consistency direction separately from earlier history.
The executable design-system typography specimen includes the operational page-header
recipe. These shared corrections are the baseline for the consumer migration, not proof
that every screen and state has already been visually checked.

## Verification for the next implementation pass

Inspect the three indexes, GST drill-down, client create/edit, and upload forms
at ordinary and wide desktop sizes. Include empty and populated states, long
identities, review states and available exports. Verify title computed styles and
header controls across routes, not only individual screenshots. Run style guard
and scoped interaction tests. A consistent family may have different compositions;
equivalent roles must retain the same visual treatment.
