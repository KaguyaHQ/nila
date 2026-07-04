# Layout Architecture

How Nila's screens are organized at the chrome level: where navigation lives,
which surfaces feel like a system of record (table, filters, archive),
which feel like a work queue (inbox, list-detail, "do the next thing"),
and how the two coexist inside one app.

This document does not decide colors, typography, components, or motion.

## Why it matters

Nila is two things at once, and most SaaS layouts only do one of them well.

- **System of record.** The receivables ledger, document archive, invoice
  history, contact directory, and configuration screens. The user is
  *browsing*: "where is the September Siemens PO?", "show me everything
  overdue more than 30 days." Density matters. Tables, filters, saved views.

- **Work queue.** The PO review pile, the approval chase, the exception
  resolution stream, the "what needs me today" surface. The user is
  *processing*, one item at a time. They want the next item to surface
  itself, full context without a reload, and a clear action on the right.

These are different cognitive tasks. Ramp/Rippling/Stripe optimize for the
first; Front/Superhuman/Things optimize for the second. Forcing both into one
pattern is what makes most enterprise apps feel exhausting.

Field discovery confirmed this split: back-office staff spend hours a day on
one-at-a-time queue work (chasing, reviewing) and also need to look up records,
run reports, and configure settings (record work). Both are first-class jobs.
For the CA engine the queue work is low-confidence classification/reconciliation
review; the record work is browsing documents, bank accounts, and clients.

## Decision

**Ramp-style shell for navigation and system-of-record surfaces.
Superhuman/Front-style list-detail cockpits for queue-shaped work.**

- A persistent left rail: org switcher at top, queue-first nav upper section
  (Today, Review, Approvals with badge counts), record modules below, user/settings
  at bottom. Collapsible to icon-only on wide-table screens.
- Inside record modules (Receivables, Invoices, Documents, Contacts): Ramp-style
  tabs, filters, saved views over a table.
- Inside queue surfaces (`/today`, Review, Approvals): two-pane list-detail —
  scrollable work items left, selected item plus actions right.
- Default route after login is `/today`.

## Surface split

| Surface                      | Mode   | UI style            |
| ---------------------------- | ------ | ------------------- |
| Left rail / global nav       | Chrome | Ramp                |
| `/today` (default home)      | Queue  | Inbox (list-detail) |
| `/receivables`               | Record | Ramp table + tabs   |
| `/invoices`                  | Record | Ramp table + tabs   |
| `/documents`                 | Record | Ramp table + tabs   |
| `/contacts`                  | Record | Ramp table          |
| `/settings`, `/connectors`   | Config | Ramp form pages     |

The split is per-mode, not per-domain. `/today` is the one actionable queue: it
absorbs document review and acceptance chase alongside receivable follow-up, each
worked from its detail pane. Documents also lives as a Ramp-table archive. Same
data, two views.

## Shell anatomy

```
┌────────────────────┬─────────────────────────────────────────────┐
│ Nila / Acme ▾    ⌕ │  page header (page title · breadcrumbs ·   │
│                    │              page-level actions)            │
│ Today          18  ├─────────────────────────────────────────────┤
│ Review          3  │                                             │
│ Approvals       7  │                                             │
│                    │  page body                                  │
│ Receivables    12  │                                             │
│ Invoices           │  (Ramp table for record pages,              │
│ Documents          │   list-detail for queue pages)              │
│ Contacts           │                                             │
│ Connectors         │                                             │
│ ───────────────    │                                             │
│ ⚙ Settings         │                                             │
│ ◐ Vasanth          │                                             │
└────────────────────┴─────────────────────────────────────────────┘
```

- Upper rail section is queue-first: Today, Review, Approvals. Counts are badges.
- Lower section is record modules. No counts — places you go to, not things that demand attention.
- Today is the aggregator: its count is the sum across queue surfaces, deduplicated.
- Rail collapses to ~56px icon-only. Receivables and the invoice editor need the horizontal room.
- Search and `⌘K` palette live at the top of the rail — power-user accelerator, not primary nav.

## Inbox cockpit anatomy

```
┌──────────────────────────┬──────────────────────────────────────┐
│ Today                    │                                      │
│ ─────────────            │  Selected item                       │
│ REVIEWS              3   │                                      │
│ ▸ Siemens PO-4421        │  - identity, status                  │
│ ▸ Philips PO-887         │  - extracted/derived data            │
│ ▸ Varian PO-1209         │  - source document (inline preview)  │
│                          │  - timeline / event history          │
│ APPROVALS            7   │  - related email or WhatsApp thread  │
│ ▸ Apollo Chennai         │                                      │
│ ▸ Manipal Bangalore      │  [Primary action]  [Secondary]       │
│                          │                                      │
│ OVERDUE             12   │                                      │
│ ▸ ₹2.4L · 47 days        │                                      │
└──────────────────────────┴──────────────────────────────────────┘
```

- Left list is the actual queue, not a nav menu. Scrolls. Items are work units.
- Clicking an item updates the right pane in place — no full reload, no losing scroll position.
- Sections by work type with counts. Empty sections collapse.
- Right pane shows full context plus the next action. The user does not have to leave to act.
- A third pane (full document preview, full email thread) is opt-in per cockpit where it pays.

## Reasoning

**First wrong turn: marketing-hero dashboard.** The old `/dashboard` re-sold the
product to someone who already bought it. Operators drop in to process work; the home
screen should tell them what needs them, not pitch the value proposition. `/dashboard`
and the separate `/approvals` cockpit are gone; their work is now actioned inline from
`/today`'s detail pane.

**Second wrong turn: sidebar vs no sidebar as the framing.** A sidebar of *modules*
makes users hunt. A sidebar of *work counts* tells them what to do. Same chrome,
opposite philosophy. The argument worth having was about contents, not the container.

**Third wrong turn: framing Nila as module-shaped.** Nila has modules, but the *job*
is "drain administrative work," which makes it queue-shaped at its core. Module-first
navigation describes the developer's mental model, not the operator's.

**The resolution: both UIs, chosen by mode.** Queue work uses inbox UI. Record work
uses Ramp UI. The rail wraps both. This reflects a real fact about the user's day.

## Alternatives considered

- **Top nav with badges (Stripe/GitHub).** Honest second place — simpler, gives back
  240px. Rejected: the PRD already lists 8–10 module-shaped surfaces with more coming,
  past the comfortable top-nav ceiling, and a top nav cannot carry an inline scrollable
  work queue.

- **Module-first sidebar (Ramp default).** Makes the operator decide "which module
  should I check first" every morning — the question Nila should answer, not ask.
  Module entries are kept but demoted below queue entries.

- **Pure inbox, no shell (Superhuman).** Beautiful for one job. Nila has too many
  record-management surfaces (Receivables, Invoices, Contacts, Settings) that are not
  queue-shaped and need tables, filters, and saved views.

- **Command palette as primary nav (Linear).** Removes the badge surface. Operators
  need to *see* "7 approvals waiting" without opening a page. Palette is added as an
  accelerator on top of the shell, not as the shell.
