# Product composition

Owns layout, density and placement. Apply [OPINIONS.md](OPINIONS.md) to decide what exists;
use [FRONTEND.md](FRONTEND.md) to implement it and [TASTE.md](TASTE.md) to judge its finish.

## Hierarchy

Start with the outcome: what Nila finished, what is usable now and what exactly remains.
Do not manufacture a region for an answer the current job does not need.

Rank content **result → remainder/consequence → action → context**. Each surface has
one focal assertion. Type, alignment and space establish hierarchy before boxes.
A container should express a real boundary, selection or floating layer.

A focused job starts on one plane. Use a split view when comparing source and correction,
or a supporting action column when it helps complete the current job. Empty monitor
width is not a reason to invent a rail. Visualizations must make a real comparison easier
while retaining exact values; never chart a number just because it exists.

## Stable page geometry

Equivalent roles use the same typography and controls; layouts may differ by task.
Use the shared page header, with `space-y-block` between it and content in the adopted
list, form and GST workspace composition. Larger gaps separate genuinely distinct
workbench regions. Avoid extra page-specific top padding.

| Surface | Width and arrangement |
| --- | --- |
| Clients/simple identity directory | Centered `max-w-[960px]` |
| Banking list and GST workspace | Centered `w-full max-w-[1400px] mx-auto` |
| Forms | Narrower reading/field width appropriate to the form |
| Document review | May use more width for source beside corrected data |

The shared shell owns outer gutters. Extra monitor width becomes balanced outer space;
a maximum is not a target. Keep text size stable as the viewport grows. Do not stretch
short lists or invent content to resemble a populated reference screenshot.

Put creation actions beside page identity, workflow actions beside their result and
period arrows in the title-actions slot. GST overview and drill-downs retain the same
period header. Avoid comparison controls and theme toggles in product pages.

## Tables and panels

- Registers are compact for scanning; evidence review has room for comparison.
- Dates, figures and outcomes have predictable widths; names use the remaining width.
  Keep short counts such as “8 documents” on one line. Right-align figures.
- Banking combines bank/account identity and the original filename. Let filenames use
  available space before truncation, and retain access to the full name.
- Align panel headers and body text, accounting for the table's own cell padding.
  Do not stack wrapper padding accidentally.
- Use clear empty states in existing destinations. Omit unrelated empty panels.

## GST month composition

The sales result and primary action sit above the schedules. A 280px Exports column
provides secondary downloads beside the schedules on wide desktops; it stacks when
space is insufficient. Keep totals on a compact line with subtle separators.

The statutory index deliberately keeps all schedules visible, in the same order and
at stable row heights. This preserves orientation and makes absence explicit during
repeated review. Empty rows are readable plain text, not badges or success claims.
Populated labels may have modest emphasis. A Prepared indicator means preparation,
never verification, approval or filing. This exception does not justify other empty cards.

A finished job leads with its result. Workings, provenance and history stay connected
for actual review rather than becoming obligatory dashboard content. Visual refinement
should reduce effort without changing these workflow boundaries.
