# Customer Workflow Discovery: Breezetech + Caltech

> Source: investigation of the family's live email accounts (May 2026). This is
> the real, end-to-end back-office workflow Nila's receivables vertical is being
> built to replace. Most of it lives only in Jaimathi's head and the family's
> institutional memory today. **If Jaimathi leaves, this knowledge walks out the
> door.** Capturing it as structured data is itself a core value of the product.

_Status: round 2. The high-value specifics (SDC definition, email patterns, routing,
cadence, sender identity) are now validated against the email data and recorded in
§8. Four items still need a direct answer from Kannan or Jaimathi (§9). The data-model
steer for planning is in §10. See the approval-chase brief for the request that
prompted this._

---

## 1. The businesses

Two related family firms, serving medical-equipment OEMs as a service partner:

- **Breezetech** (proprietor: Hema / Hemalatha).
- **Caltech** (Caltech Refrigeration, proprietor: Kannan).

**Both firms bill all OEMs.** The split is by proprietor, not by client (corrected
from earlier rounds; see §14.1). The OEM list is **four**, not the three originally
captured: **Siemens Healthineers** (which now includes Varian post-acquisition),
**Philips**, **Elekta**, and **GE Healthcare**.

Both run the same lifecycle (quote → PO → service/report → invoice → approval →
GRN → payment) but the **mechanics differ sharply per OEM** (Philips SDC, Siemens GRN
chain, Elekta direct/compliance-strict, GE Healthcare same-day approval), which is
the central finding: there is no single workflow.

The investigated invoice/ops account is **caltechrefrigerationoffice@gmail.com**
(the account they actually use for invoicing on the Caltech side). The Breezetech
side was investigated separately (breezetechdocuments@gmail.com).

---

## 2. Email account inventory (7 inboxes, 3 people)

No shared visibility. GST data and invoices are forwarded **between accounts by
hand**. Jaimathi switches accounts depending on which company she is sending for.
Invoices have been sent from the wrong account (Breezetech invoice 16 was "already
sent from another mail ID" and had to be re-sent).

| Account | Person | Used for |
|---|---|---|
| `kannancaltech@gmail.com` | Kannan (dad) | Personal / Caltech, GST data source |
| `hemabreezetech@gmail.com` | Hema (mom) | Breezetech |
| `breezetechoffice@gmail.com` | Jaimathi | Breezetech **quotes** (round 5, distinct from invoicing account) |
| `breezetechdocuments@gmail.com` | Jaimathi | Breezetech office (invoicing / SDC) |
| `caltechrefrigerationoffice@gmail.com` | Jaimathi | Caltech office (invoicing) |
| `caltechbreezetechgrn@gmail.com` | shared | GRN tracking |
| `caltechbreezetechservice@gmail.com` | shared | Service requests / field dispatch (§12.4) |

Account boundaries are **fluid**: Kannan sometimes replies from Hema's account signing
his own name, and Siemens engineers (e.g. Tom Thelleyil) blast urgent call notifications
to **all** accounts at once. The team's working model is "everyone CC'd on everything."

**Implication for Nila:** one shared, audited workspace replaces seven uncoordinated
inboxes, and ingestion must be **multi-inbox from the start**, not one canonical mailbox.
The two Breezetech accounts (`breezetechoffice@` for quotes, `breezetechdocuments@` for
invoicing) plus the PO-arrival inbox (`hemabreezetech@`) are the proof case: a Philips
PO sent to one inbox is invisible to the person sending reminders from another (see
§14.2). For Philips SDC v1 specifically, reads stay single-inbox: approval replies land
on the original thread in `breezetechdocuments@`. Which sending identity Nila uses is
settled for Philips in §8.7.

---

## 3. Master contact + routing map

Region-to-person routing currently lives entirely in Jaimathi's memory. There is no
contacts entity in Nila today, and `site_location` is free text. This table is the
ground truth to model.

| OEM | Contact | Role | Region | Speed / notes |
|---|---|---|---|---|
| **Siemens** | Solomon H | Main coordinator, GRN approver | All India | Good when present; **3-week emergency leave** Apr 29–May 20 froze the pipeline |
| Siemens | Asha NK | Finance / OTC | All India | Responsive; handles invoice queries + revisions |
| Siemens | Rahul Lionel-Lobo / `SHS_CS_GRNBooking.gbs@siemens.com` | GRN booking team | All India | 1–3 day turnaround after Solomon approves |
| Siemens | Santosh Valecha | Central procurement | Mumbai | Slow, needs reminders; CC'd on every quote |
| Siemens | Kalyan Kumar A | Regional engineer | Hyderabad / Telangana | Fast approver |
| Siemens | Ranjith TP | Regional engineer | Bangalore / Karnataka | Travels frequently |
| Siemens | Yasin Shaik | Regional engineer | AP | Responsive |
| Siemens | Bhupinder Pathania | Regional engineer | North India | Travels for workshops |
| Siemens (portal) | `apindiadigitalinvoicescanning.in@siemens.com` | Automated invoice scanning | — | Machine endpoint, not a person |
| **Philips** | Mohanraj Maruthi | SDM (approver) | Tamil Nadu | Travels constantly |
| Philips | Ramkumar KM | SDM | Karnataka / Kerala | Medium speed |
| Philips | Vignesh K | SDM | Telangana | Fast approver |
| Philips | Jagadish Yenda | SDM | AP | Slowest, needs 3+ reminders |
| Philips | Sreejith SS | SDM | Kerala (backup) | Responsive |
| **Elekta** | Jyoti Negi | Commercial ops | All India | Responsive, **strict on GST compliance** |
| Elekta | Deepak KU | Engineering | — | Quote recipient |

Region mapping is the highest-value, highest-risk rule: a single mis-route (Philips
SDC 163 went to Mohanraj/TN when the site was Telangana) costs a correction email and
days of delay.

---

## 4. The three OEM workflows

### 4.1 Philips (Breezetech): single-approver SDC chase

1. Jaimathi emails an **SDC approval request** to the one regional SDM (per the map
   above), with the standard invoice table (Invoice No, Date, Value, PO No, Claim
   Description).
2. Manager replies **"Approved"** plus the table echoed back.
3. If no reply, Jaimathi sends **manual reminders** — frequently 2, 3, even 4. Jagadish
   SDC 149/150 needed **three reminders over 13 days** before approval.
4. After approval, follow up again for the actual **payment release**.

Volume: 36+ Breezetech invoices in two months, ~100+ emails/month just for approvals.
Bottlenecks: **Jagadish (slow), Mohanraj (always travelling)**. No escalation path.

**Lifecycle position (validated):** `invoiced → sdc_sent → sdc_approved → paid`. For
Philips there is no `sent` distinct from `sdc_sent`; sending the invoice **is** the
SDC request. **Granularity: per-invoice** (one Gmail thread = one approvable unit),
even when several are composed in one session. The SDC number equals the Breezetech
invoice number (SDC NO-149-2025-26 = invoice 149/2025-26), and is Breezetech-side.

### 4.2 Siemens (Caltech): dual-email submission + multi-party GRN chain

This is **harder than Philips** because approval is a chain, not one person.

1. **Quote** goes to **two** recipients: the regional engineer (Kalyan=Hyderabad,
   Ranjith=Bangalore, Yasin=AP, Bhupinder=North) **and** central procurement
   (Santosh Valecha, Mumbai). Same quote, two emails, different CC lists.
2. Regional engineer approves ("Approved. Pls proceed" / "OK, PO will be released").
   Auto-replies common ("on leave till 4th May", "travelling for MTA workshop").
3. **PO receipt** from Siemens (via Solomon) or Elekta.
4. **Invoice submission = TWO emails, every time:**
   - Email 1: invoice to `apindiadigitalinvoicescanning.in@siemens.com` (scanning
     portal), CC Solomon, Asha, Rahul, the GRN tracking account, Kannan.
   - Email 2: the supporting document to `solomon.h@siemens-healthineers.com`
     separately.
   - 29 Caltech invoices this year = 58 submission emails before any follow-up. On
     Apr 29 alone Jaimathi sent invoices 20–24 = **10 emails in one day**.
5. **Solomon requests missing docs or flags errors** ("share the service report to
   process GRN"; tax-treatment rejections).
6. **GRN approval + booking:** Solomon reviews → emails Rahul "Pl proceed with the
   GRN" → Rahul books and replies with **GRN numbers** (1–3 days). Solomon batches
   4–5 invoices at a time.
7. **Payment chase:** Jaimathi sends a "Payment Pending Details" summary; Solomon
   forwards to Asha (finance) + Rahul; they share a Google Sheet of payment status.
   This is the manual version of the "money map" feature.

**Single point of failure:** Solomon's 3-week leave (Apr 29–May 20) froze the entire
Caltech pipeline. Invoices 20–29 sat un-approved, no GRN booking, no payment, **no
escalation to Asha or anyone else**.

### 4.3 Elekta: direct, compliance-strict

POs arrive from `Jyoti.Negi@elekta.com` with PO number, site, and description in the
**subject line**. Jyoti is strict on GST compliance and bounces non-compliant invoices
(see §5). Quote 13 was resubmitted "with a negotiated 5% reduction" — a manual
recalculate-and-regenerate cycle.

---

## 5. Compliance + data-integrity errors (Nila's prevention surface)

These are the concrete, recurring errors that block payments. Each is a validation
Nila can enforce so the error becomes impossible.

1. **IGST vs CGST/SGST applied wrong.** Invoice 142/2025-26 used CGST/SGST where IGST
   was required. GRN booking rejected it → returned → **cancelled and reissued as
   145/2025-26**. Weeks of delay. Correct treatment is derivable from **Place of
   Supply** vs supplier state.
2. **Missing Place of Supply.** Elekta returned invoice 153/2025-26 to add "Place of
   Supply – Haryana." This field decides IGST vs CGST/SGST; missing it = rejection,
   revision, re-send, re-approve.
3. **PO date validation.** Philips PO 4700324848 had contract period "01-Nov-25 to
   31-Oct-25" (end before start). DVIMS vendor portal rejected the invoice; required an
   amended PO routed through Vignesh → procurement. A trivial date check at PO ingestion
   catches this before work begins.
4. **Cancelled-invoice tracking.** Invoice 142 was cancelled and replaced by 145 but
   Asha was never properly told. Cancelled invoices with no linkage = confusion + delay.
5. **Quote number collisions.** Quote 16 was reused for two different sites/jobs
   (Manipal Bangalore coil replacement AND Sai Vijaya Scan Ongole water supply).
   Manual numbering with no uniqueness enforcement.
6. **Duplicate / wrong-account sends.** Same invoice sent from two accounts; wrong-region
   routing (Philips SDC 163). Both stem from no single source of truth.

---

## 6. Consolidated pain map

| Pain | Philips (Breezetech) | Siemens (Caltech) |
|---|---|---|
| Emails per invoice | 1 (SDC approval) | 2 (invoice + supporting doc) |
| Approval process | One regional SDM | Multi-party chain (Solomon → Rahul → GRN team) |
| Follow-up style | Reminders to one person | They mostly just wait |
| Key bottleneck | Jagadish (slow), Mohanraj (travels) | Solomon (single point of failure, 3-week leave) |
| Compliance error | PO date typos | Missing Place of Supply; IGST/CGST mix-up |
| Email accounts | 2 | 3 |

The Siemens side is scarier: when one person is out, the pipeline **stops** with no
visibility into the financial impact.

---

## 7. Implications for the three killer features

1. **Approval chase** must cover **both** models: Philips single-approver SDC and
   Siemens multi-party chain (Solomon → Rahul → GRN). It must **detect an unresponsive
   key person** (auto-reply / silence) and surface an **escalation** path (e.g. Solomon
   out → route to Asha). Daily surface: "N approvals overdue, X hasn't responded in D
   days, tap to send reminders."
2. **Quote/invoice generation** must auto-populate **Place of Supply**, derive **IGST
   vs CGST/SGST** from it, enforce **PO date validity** and **quote-number uniqueness**
   at ingestion, and support a "regenerate with N% discount" path. This kills the
   reject → revise → resubmit cycles.
3. **Money map** becomes critical precisely because the pipeline can silently freeze
   (Solomon's leave). It needs per-invoice stage visibility and impact ("₹X stuck
   because GRN booking is blocked on one person").

---

## 8. Ground-truth answers (validated from email, round 2)

### 8.1 SDC definition

**SDC = Service Delivery Confirmation**, Philips's internal approval that authorizes
payment for completed work. Philips-only (Siemens uses GRN booking, Elekta has no
approval step). Number equals the Breezetech invoice number. Pipeline position and
granularity recorded in §4.1. The "Service Delivery Confirmation" expansion itself is
inferred, not operator-confirmed (§9).

### 8.2 Subject-line patterns

Observed across 30+ threads. The SDC number is reliably present; surrounding format is not:

- `SDC NO-36-2026-27 Approval Reg`
- `SDC NO-35-2026-27 Approval Reg.`
- `SDC NO-32-2026-27 Approval Reg.,`
- `Breezetech Invoice 34-2026-27` (variant, no "SDC NO" prefix)

Pattern: `SDC NO-{N}-{FY} Approval Reg` with variable trailing punctuation, or
`Breezetech Invoice {N}-{FY}`. A tolerant regex extracts `(sdc_number, fy)`. **Do not
thread on subject** given the variants; thread on Gmail `threadId`.

### 8.3 Approval reply variants

The word **"Approved" is always present**; the invoice table is echoed back in 4 of 5 cases:

- Common (Mohanraj, Ramkumar): "Approved to process the following Invoice" + table + signature
- Vignesh: "Hi, Approved for the below details:" + table
- Ramkumar variant: "Dear Team, Approved SDC" + table
- Jagadish minimal: "Approved" (single word, sometimes no table)
- Forwarded/handover (SDC 23): Ramkumar forwarded to Sreejith, who replied "Pls find attached approved SDC"

**Reply parsing:** `\bApproved\b` on the body is a ~95% solution; a model gets ~99%. The
risk is false **positives** from auto-replies, not false negatives. Filter auto-replies
first, then string-match.

### 8.4 Auto-reply detection (must be classified as not-approval)

- "I am travelling for customer visits. Please expect a delay in my response." (Mohanraj)
- "Today I am on Leave and response may be delayed"
- "I'm on leave till 04th May and have no access to emails. Please expect a delay." (Ranjith, Siemens)
- "I am on personal emergency leave from 29.04.2026 till 20.05.2026" (Solomon, Siemens)

Reliable heuristic: contains **"delay" + ("leave" OR "travelling" OR "out of office")**,
and Gmail often adds an `Automatic reply:` subject prefix. Filter these before the
Approved match so an out-of-office never false-closes the loop.

### 8.5 Reminder format + cadence

Reminders are sent **as a reply on the original thread** (so the `threadId` already
links them; no subject matching needed). Body: "This is a gentle reminder ... Kindly
confirm and Approve the Attached SDC" + table.

| Invoice (approver) | Sent | Reminder 1 | Reminder 2 | Reminder 3 | Approved |
|---|---|---|---|---|---|
| SDC 149/150 (Jagadish) | Feb 4 | Feb 11 (+7d) | Feb 13 (+2d) | Feb 17 (+4d) | Feb 17 (+13d) |
| SDC 27/2026-27 (Mohanraj) | May 12 | May 19 (+7d) | n/a | n/a | May 20 (+8d) |
| SDC 156-158 (Jagadish) | Feb 24 | Mar 5 (+10d) | n/a | n/a | Mar 6 (+11d) |

Pattern: first reminder ~day 7, follow-ups every 2 to 4 days. **Calendar days, IST.**
The cadence is **not** per-manager: Jaimathi uses the same rhythm for everyone; slow
approvers just need more cycles. Build one cadence (≈ day 7, 11, 15) plus a manual
"remind now" button. Approval speed by approver: Mohanraj/Vignesh within hours,
Ramkumar 1 to 2 days, Jagadish 7 to 13 days with multiple reminders.

### 8.6 Routing map (confirmed) + site→region

Confirms §3. Philips approver emails:

| Manager | Email | Region |
|---|---|---|
| Mohanraj Maruthi | Mohanraj.Maruthi@philips.com | Tamil Nadu |
| Vignesh K | vignesh.k@philips.com | Telangana |
| Ramkumar KM | ramkumar.km@philips.com | Karnataka + Kerala |
| Jagadish Yenda | jagadish.yenda@philips.com | Andhra Pradesh |
| Sreejith SS | SS.Sreejith@philips.com | Kerala (Ramkumar backup/handover) |

Real site→region examples (for seeding a sites lookup):

- Sri Sakthi Amma Trust Vellore, Pudhukottai GH, Tirunelveli, Clarity Imaging Coimbatore, Aarthi Scans Kilpauk → Tamil Nadu
- NH Bangalore, Command Hospital Bangalore → Karnataka
- ESI Hyderabad, MNJ Hyderabad, Konnect Hospital Attapur → Telangana
- Sathya Scan Rajamundry, Government Siddhartha Medical (Vijayawada) → Andhra Pradesh
- Baby Hospital Calicut, Lakeshore Ernakulam → Kerala
- Aarupadai Veedu Medical College → Pondicherry? (uncertain, see §9)

**Region inference is lookup-and-fallback, not pure pattern matching.** Some sites name
the city (easy); others name only the hospital (Lakeshore, NH, Baby Hospital, needs a
sites table or a model). Plan: seed a **sites table from the existing PO Entry sheet**
(it carries both site name and routing), fall back to a model only for new sites.

### 8.7 CC conventions, escalation, sender identity

- **CC:** every Philips SDC email From `breezetechdocuments@` CCs `hemabreezetech@` (Hema);
  the manager's reply also CCs Hema. **No** Kannan CC on the Philips chain.
- **Escalation: not in the data.** Sreejith handled SDC 23 only because Ramkumar
  *forwarded* it, not via a Breezetech escalation rule. There is no observable "if silent
  N days, escalate to X." Treat escalation as out of scope for v1 unless §9 says otherwise.
- **Sender identity:** `breezetechdocuments@gmail.com` is authoritative for Philips
  (Hema's account sent 1 to 2 of 36+ and caused the invoice-16 duplicate). **Lock the
  sender.** Architecture: send via **Gmail send scope from breezetechdocuments@** so
  replies stay on the existing threads; a Nila-domain From would break reply chains.

### 8.8 Correction + PO-error cases (verbatim)

- **SDC 163 correction:** "This pertains to a Telangana site. Kindly ignore Breezetech
  Invoice No. 163/2025-26." Sent to Mohanraj (TN) when it should have gone to Vignesh
  (TL). Root cause was **wrong region inference, not a typo.** The fix is smarter routing
  plus a pre-send recipient confirmation, not just verification.
- **PO 4700324848:** contract period "01-Nov-25 to 31-Oct-25" (end before start).
  Breezetech asked for an amended PO. This is a **PO-ingestion validation**, not an
  invoice-send check.

### 8.9 UX recommendation (validated)

- **Compose-then-confirm, not one-tap.** SDC 163 proves that a tap-to-send pipeline with
  the same routing logic would repeat the error. Pre-send confirm: "Sending SDC
  163/2025-26 to Mohanraj Maruthi (Tamil Nadu). Confirm or change recipient."
- **In-app cockpit, not a digest email.** Jaimathi is in the app daily for invoicing; the
  overdue list lives beside the operations she already works.
- **Auto-advance on Approved + audit event + easy undo**, but only after the auto-reply
  filter (§8.4) runs first.

## 9. Still needs the operators (10-minute questions)

More email searching will not resolve these; they need Kannan or Jaimathi:

1. Does "SDC" stand for **Service Delivery Confirmation** specifically, or another Philips term?
2. Is **Aarupadai Veedu Medical College** routed as Pondicherry or Tamil Nadu?
3. Is there an **unofficial escalation path** when a manager goes dark (a phone call, a
   different contact) that never appears in email?
4. Does Philips ever **reject** an SDC (vs just going silent), and what does that look like?

## 10. Data-model steer for planning (read before designing)

The single most important planning takeaway from round 2: **"SDC approval chase" is one
of three structurally different approval chases, not the whole feature.** Modeling only
Philips SDC captures ~30 to 40% of the pain.

- **Philips SDC:** single approver, one email, reply "Approved". State machine:
  `sdc_sent → sdc_approved`.
- **Siemens GRN chain:** two submission emails (scanning portal + supporting doc to
  Solomon), then Solomon forwards to the GRN booking team, Rahul replies with GRN numbers.
  Three parties, two stages. Different state machine entirely.
- **Elekta revision cycle:** no approval; invoices get **bounced for compliance** ("add
  Place of Supply – Haryana"), requiring regeneration. The action is a revision request,
  not an approval.

A single linear status on `Operation` cannot hold all three. **Recommendation:** model an
**`ApprovalRequest`** entity attached to an `Operation`, where `oem` selects the state
machine (SDC / GRN-chain / revision-cycle). The **contacts table is OEM-scoped**; the
**cadence rules are shared**; the **daily cockpit unions across all three**. If we still
ship SDC-only for v1, the schema should anticipate the other two so we don't refactor in
two weeks.

**Two dependencies this feature assumes but Nila does not yet have:**

- **Sending email.** Current Gmail integration is read/attachment-sync only. Outbound needs
  Gmail **send** scope on `breezetechdocuments@` plus a send path and templates (none exist).
- **Auth + roles.** The "daily surface with Jaimathi=send, Hema/Kannan=read" model needs
  the authentication + RBAC that the PRD lists as **P0 and not yet built**. The feature's
  multi-user visibility is blocked on that.

## 11. Build decisions (settled)

- **Scope / data model:** build the generic, **extensible** abstraction properly per
  Nila's principles (an `ApprovalRequest` whose `oem` selects the state machine,
  OEM-scoped contacts, a sites lookup, shared cadence rules, a cockpit that unions across
  OEMs). Implement the **Philips SDC** state machine first; Siemens GRN and Elekta revision
  cycles must slot in later with no schema refactor. Clean and extensible over fastest.
- **Dependencies:** v1 is **single-user (Jaimathi), send included.** No auth/RBAC gate yet
  (keep the current first-user mount); do wire **Gmail send scope** on
  `breezetechdocuments@` so it actually sends. Multi-user read access (Hema/Kannan) waits
  for the P0 auth work.

## 13. Round 4 findings: the CA cycle (corrects §12.1) + newly visible ops layers

_Source: searches of `kannancaltech@gmail.com` (Kannan's account; already listed in §2 as
"GST data source"). Round 3 only searched the office accounts, so the CA traffic, which
runs to Kannan, never showed up. It was always there._

### 13.1 The CA firm

**Balaji Vasudevan & Co.** (`mail@bvccas.com`, bvccas.com, Chennai). Junior staff rotates
each month (Janani, Bhuvaneshwari, Rajashree, Sadam Hussain were observed). No continuity
across cycles; senior partners stay in the background. The firm manages **Caltech and
Breezetech as a unified operation**.

### 13.2 Monthly GST cycle (5 steps, zero judgment work)

1. **Day 1 of month:** a CA junior emails Kannan (CC Hema): "Kindly share [month] sales
   and purchase invoices for GST Filings."
2. **+2 to 4 days** (often after a reminder): Kannan replies with attachments.
   **Sales side only**; purchase invoices are sent separately or not at all.
3. **+2 to 3 weeks:** CA sends the **GST challan** with a specific amount, e.g.
   "GST Payable Rs. 1,17,662/-".
4. Hema pays via bank, sends payment proof back ("PFA Kindly do the needful").
5. CA files **GSTR-3B**.

Pure data processing, handled by a different junior every month. No advisory content.

### 13.3 Quarterly advance income tax

CA sends a per-entity reminder with the amount and deadline: "Caltech Refrigeration:
Rs. 1,00,000/-, Breeze Tech (Hemalatha): Rs. 1,00,000/-". Hema pays, sends the receipt.
~₹1L per entity per quarter implies an **estimated ~₹8L combined annual income tax**.

### 13.4 Annual year-end document chase

- **April 30, 2026 request:** bank statement (Apr 2025 to Mar 2026), **IOB loan statement**
  (business debt now confirmed), **Breeze Tech GST login credentials**.
- **September 2025 (FY 2024-25):** FD closing balance, interest certificate.

The credential request is significant: the CA does **not** have persistent GST portal
access; credentials are shared each filing. That is insecure (passwords in email) and it
means the CA **cannot proactively monitor** the portal for notices, ITC mismatches, or
system flags. A GSP-API path through Nila would fix both.

### 13.5 Ad-hoc compliance for OEM vendor registration

Triggered whenever an OEM (Philips and similar) onboards or recertifies them as a vendor:
ITR portal screenshots, PAN-Aadhaar link status, **Form 206AB declaration**, audited
financials (BS, P&L, computation, ITR ack) for the last 3 years. Recurring across the
year as new OEM relationships open.

### 13.6 Other operations layers newly visible

- **DVIMS / InvoiceComply portal (Philips):** Hema uploads invoices to a **buyer-side
  compliance portal** in addition to the SDC email chain. Portal errors and rejections
  are a separate high-pain failure mode (distinct from SDC chase). The Philips workflow
  is therefore **SDC email + DVIMS upload**, not SDC alone. The shipped
  `ApprovalRequest` abstraction does **not** model portal upload yet;
  worth a separate "portal submission with rejection handling" workflow type later.
- **Vendor payments:** Hema pays vendors via **Kotak IMPS**, manual transfers, no system.
- **Worker payments:** also manual via Kotak IMPS, **no payroll system**. PF/PT/TDS
  compliance risk; outside Nila's receivables/GST scope but worth flagging.
- **Payment detection (bank side):** Hema reads bank alerts + the IOB app. This is the
  only inbound "did the money land?" signal today, which reinforces §12.1: payment is
  invisible to email, so auto-`paid` needs bank/Account Aggregator data.
- **Business loan:** **IOB business loan** confirmed. EMIs are a real recurring cash
  outflow the money map should reflect.

### 13.7 Implications for Nila (this changes the product story)

- **The monthly CA cycle is the single most automatable thing in the whole business.**
  Nila already holds the operations ledger, so it has the underlying sales + purchase
  data without anyone re-sending it. Compute liability, generate the challan, file
  GSTR-3B via a **GSP API** (ClearTax / IRIS / Cygnet GSP). The CA's monthly role goes
  to near zero. This **replaces** the earlier "CA handoff is post-MVP / WhatsApp" framing
  in §12.1.
- **The CA stays valuable at the boundaries:** annual tax computation, planning, audit
  prep, ad-hoc compliance / vendor-registration packages. Nila is **with** the CA, not
  against them. Position accordingly.
- **GSP-API access is itself a feature**, not just plumbing. Persistent secure access
  enables proactive monitoring (GSTR-2B mismatches, ITC opportunities, portal notices)
  that the current monthly-credential-share model structurally cannot do.
- **The money map gains real cash-outflow lines:** IOB loan EMI, advance tax (₹1L per
  entity per quarter, predictable), monthly GST liability. "Cash going out" is now
  modelable alongside "cash coming in," which is the part of the picture that has been
  missing.
- **Position shift:** "replace the next hire" (round 3, §12.5) sharpens further. The CA
  monthly cycle is the equivalent of half a finance hire that Nila absorbs.

## 14. Round 5 findings: corrections, new OEMs, structural inbox gap, inventory, errors

_Source: searches across the three primary accounts (`kannancaltech@`, `hemabreezetech@`,
`breezetechdocuments@`) plus the previously-unlisted `breezetechoffice@` (Jaimathi's
quotes inbox). Three corrections to earlier rounds plus several new pain categories._

### 14.1 Corrections to earlier rounds

- **§1 framing was wrong.** "Breezetech = Philips, Caltech = Siemens + Elekta" assumed a
  client split. Reality: the split is **by proprietor** (Kannan owns Caltech, Hema owns
  Breezetech), and **both firms bill all OEMs**. Round-5 quote inventory from
  `breezetechoffice@`: 01-05, 07, 09-12, 16-21 → Philips; **08 → Siemens** (Ranjith TP,
  Bangalore); **06 → Varian** (Bijuraj, GH Linac Coimbatore). Caltech sends to Elekta and
  occasionally Philips. **Implication for the SDC plan:** `Nila.Contacts.OemContact` is
  already OEM-scoped, so the schema holds; only the seed data and the routing UX need to
  allow either billing org to address any OEM. `org_id` remains the billing entity for
  receivables and GST.
- **§2 missed one inbox.** Added `breezetechoffice@` above. Seven inboxes, not six.
- **The OEM list is four, not three.**
  - **GE Healthcare is a fourth client.** Sudha R (`sudha.r@gehealthcare.com`) emails
    Kannan directly. Observed: CMC quote for Ramakrishna Hospital Coimbatore (22TR
    chiller), Senthil forwards to Sudha, **same-day approval**. Fastest cycle of any OEM.
    Missed earlier because GE is small/newer and absent from the PO Entry sheet.
  - **Varian is part of Siemens Healthineers** post-acquisition. Mid-thread, Bijuraj's
    domain switches from `@varian.com` to `@siemens-healthineers.com`. Treat as a Siemens
    sub-brand for contacts and workflow.
  - **Implication for `Operation.oem` enum** (currently `siemens|philips|varian|elekta`):
    add **`ge_healthcare`**; keep `varian` for backward compatibility but route it through
    the Siemens contacts/workflow. Code change deferred; flag for the next build phase.

### 14.2 The structural PO-inbox gap (Quote 02 Trivandrum was not a freak)

**The case.** Quote 02 sent to Ramkumar from `breezetechoffice@`. PO arrived **13 Apr**
from `south.west_logistics@philips.com` to `hemabreezetech@`. Subject:
`RE: REQ_3354 - New PO creation Request`, no quote-number reference. Jaimathi (working in
`breezetechoffice@`) had no visibility into Hema's inbox. She sent a reminder **May 9, 26
days after the PO arrived**. Sreejith replied "PO already shared on 13th Apr."

**It is structural, not a freak.** 15+ Philips POs in the last 60 days, **all** of them:

- From `south.west_logistics@philips.com` to `hemabreezetech@`.
- Subject pattern `RE: REQ_XXXX - New PO creation Request`, **zero quote-number reference**.
- CC the regional SDM (Ramkumar / Mohanraj / Jagadish / Vignesh) and Nitin Bonde.
- **Never** CC `breezetechoffice@` or `breezetechdocuments@` (where Jaimathi works).

POs and quotes live in different inboxes, with subjects that don't thread, sent by people
the quoting team doesn't correspond with directly. The PO Entry sheet is the only shared
state, updated manually only when someone notices.

**Implication.** The operations dashboard's value isn't only chase visibility; it is
**shared state across inboxes**. PO-ingestion needs to: poll the Philips logistics sender
across all inboxes, parse the attached PDF, match to a pending quote by OEM + site +
amount + date, mark the operation `po_received`, and **suppress quote-approval reminders**
once a PO has landed. Frequency of the embarrassment is uncertain (one clear case
observed), but the conditions make it recurring rather than incidental.

### 14.3 The quote-to-PO cycle is richer than mapped

The earlier flows treated quote → approval → PO as a clean three-step. Round 5 shows
intermediate stages:

- **Service-report requests.** Varian (Bijuraj) on Quote 06 GH Linac Coimbatore: "Please
  share a service report on why we have to do this insulation." Field engineer (Narendran)
  signs and sends a separate report before approval moves.
- **Multiple revision cycles.** Quote 17 Kilpauk: Mohanraj asks for revision, Jaimathi
  revises, "Initiated for next level of processing," another revision the following week.
  Quotes routinely iterate 2 to 3 times before PO.
- **Phone/WhatsApp decisions that never hit email.** Quote 10 SIMS Vadapalani killed via
  a call between Kannan and the Philips SDM: Mohanraj revealed "Last night, Thippu, Kannan
  and I had a call. Condenser coil can be managed for another year." **Email is the
  execution and paper-trail layer; phone and WhatsApp are the decision layer.** Unless
  Nila ingests WhatsApp too, an Operation can sit `quoted` forever after the real decision
  happened off-channel. Worth modeling a "decision channel" / "stale-on-email" flag.

### 14.4 OEM-specific PO parseability

PO emails differ drastically in machine-parseability, which matters for the
PO-ingestion worker:

- **Elekta (cleanest).** Subject e.g. `PO#EL00375130_06-Mar-26_Dr. Kamakshi Memorial Hospital_Caltech Refrigeration`. PO number, date, site, vendor all in the subject. Regex-parseable.
- **Siemens (medium).** Structured-ish, but service-request prefixed.
- **Philips (worst).** `RE: REQ_3533 - New PO creation Request`. Subject is opaque; must
  parse the attached PDF and fuzzy-match the site name to a pending quote.

A PO-ingestion worker should expect a fast regex path for Elekta and a PDF + fuzzy-match
fallback for Philips.

### 14.5 Inventory + local-purchase (money leak, future scope)

- **Unbilled / unreturned parts.** Nirman Hi-Tech Mumbai: two ACS coils air-shipped, **one
  billed, one unbilled, one unreturned** 6+ weeks later (~₹33,320 per coil at risk).
  Kannan tracking it from memory. No system links parts shipped to parts billed to parts
  returned.
- **Local-purchase-and-claim flow.** Rupesh (Siemens) on the Aarthi Kilpauk MCCB:
  "Purchase locally and claim." Kannan buys out-of-pocket from a local dealer, installs,
  then bills the OEM. **If the local purchase receipt isn't captured, the ITC is lost and
  the expense never hits the P&L.** Pairs naturally with the Porter ITC stream (§12.2):
  every local purchase invoice arriving by email should auto-link to the job it was bought
  for.
- **Implication.** Future scope: a **Parts/Inventory ledger** tied to `Operation`, with
  an "expected to be billed" flag that ages and surfaces unbilled items. Separate from
  approvals and receivables; probably a future `Nila.Parts` context. Not v1, but the data
  model should not preclude it.

### 14.6 Kannan as human email router (auto-classifier opportunity)

Everything personal-ish arrives at `kannancaltech@`. Kannan reads on his phone and
forwards to the right office account with the universal phrase **"PFA Kindly do the
Needful."** Observed routes:

- Zoho purchase invoice → `breezetechdocuments@` (purchase-side ITC)
- CA GSTR-2B → `breezetechdocuments@` (in 2 minutes; see §14.7)
- Elekta AMC agreement → `caltechrefrigerationoffice@` (operations)
- Johnson Lifts elevator offer → `caltechrefrigerationoffice@` (personal, mis-routed)

**Implication.** The inbound-connector layer can grow an auto-classifier that reads
incoming attachments and routes them to the right context (purchase ITC, operations,
contracts, personal) without Kannan in the loop. Removes a real time sink and a
mis-routing source.

### 14.7 CA cycle: faster than §13 thought, and a confirmation trace

End-to-end timing observed for the April 2026 filing:

- **May 18, 12:55 PM:** CA junior **Narshika R** (sixth observed name, after
  Periyadharan, Janani, Bhuvaneshwari, Rajashree, Sadam Hussain) sends GSTR-2B to Kannan.
- **May 18, 12:57 PM:** Kannan forwards to `breezetechdocuments@` (**2 minutes**).
- **May 19, 2:45 PM:** CA returns the GST challan, **₹1,10,966**.
- **May 20:** **IOB Tax/Bill payment of ₹1,10,966** (exact match) from Kannan's bank.

The full CA-to-pay cycle is **one day**, not weeks. Actual CA processing is hours of
mechanical data entry. The ₹1L payment trace is direct confirmation of §13.2 and pins
the GSP-API automation thesis: this is the most automatable thing in the business.

### 14.8 Kannan: iTracer access + UX implications

- **iTracer vendor ID: 1000212298** (Siemens vendor portal). Kannan resets passwords and
  OTP-logs in personally to check payment status. Portal is known buggy (§12.3). A
  Siemens-payment-status surface in the money map removes the trip to iTracer entirely.
- **Mobile-first, informal writing.** Example: *"Part booked Chennai Air port plz collect
  at Mumbai yearly morning all documents shared."* No punctuation, stream of consciousness
  from Gmail Mobile. **He will not fill a form.** Any Kannan-facing input must accept
  natural-language stream-of-consciousness and structure it server-side. This is a UX
  principle, not a feature.
- **Personal/business mixing.** Kannan paid ₹15,365 to a parts vendor from his **personal
  Kotak (xx6188)**, separate from Breezetech's (xx5511). Forwarded a Johnson Lifts
  elevator offer (personal) into a business account. Any bank-statement parsing must flag
  personal vs business; the CA disentangles this by hand today.
- **Travel-booking time sink.** Kannan books RedBus / IRCTC / IndiGo for technicians
  (Kalidoss VSK → Ongole, etc.). Admin overhead unrelated to core business; out of MVP
  scope, useful color on where his time goes.

### 14.9 The error taxonomy (Nila's prevention surface, consolidated)

Every observed error across rounds 1 to 5 falls into one of four buckets. Each is a
prevention surface, not a judgment call.

| Bucket | Observed examples | Nila prevention |
|---|---|---|
| Tax treatment | Invoice 142 CGST/SGST instead of IGST; DI Water 18% instead of 5%; missing Place of Supply Haryana; three invoices cancelled in one FY (120, 137, 142) | Derive IGST vs CGST/SGST from Place of Supply; HSN-driven GST rates; mandate Place of Supply at invoice gen |
| Document validation | E-way bill amount ≠ invoice amount (Invoice 34); missing e-way bill for self-transport (Invoice 26, Shimoga coil); HSN mismatch on DVIMS; iTracer total outage | Per-portal pre-submission validators (DVIMS, iTracer) before upload |
| Routing / tracking | SDC 163 wrong region; Trivandrum PO unseen for 26 days (§14.2); Invoice 16 sent from wrong account | Contacts directory + region routing (SDC plan Phase 1); shared multi-inbox state; PO-to-quote auto-link |
| Inventory | Two coils unbilled/unreturned at Nirman Hi-Tech (~₹33K each); local-purchase MCCB receipts uncaptured | Parts ledger tied to Operation; "expected to be billed" aging; local-purchase invoice auto-ingest |

**Judgment work has zero errors in the data.** Technical diagnosis, scope negotiation
with OEM engineers, repair-vs-replace calls: Kannan's brain is reliable. The
administrative system around it is not. That is the product story.

### 14.10 Strategic framing (placeholder, belongs in PRD)

Closest historical comp: **ServiceTitan** (US, HVAC/plumbing/electrical contractors,
vertical SaaS, ~$9.5B). Same structural pain (field service business running on paper,
spreadsheets, phone calls). Difference in paradigm: ServiceTitan is forms-and-dashboards
SaaS; **Nila's bet is AI-native**, so the field operator never touches a form. Sector
shorthand: **vertical-SaaS × AI × India**, or "AI-native ERP for Indian SMEs in
compliance-heavy verticals, starting with field-service / maintenance contractors." Worth
folding into PRD §1 in a later pass; flagged here so it doesn't get lost.

## 12. Round 3 findings (visibility gaps + adjacent workflows)

Source: 180+ day search of `caltechrefrigerationoffice@gmail.com`. These mostly inform the
**money map** and **GST** features, not Philips SDC v1. The one SDC-relevant takeaway:
payment is not visible in email, so v1 marks `paid` **manually** (see 12.1).

### 12.1 What is NOT in email (corrects earlier assumptions)

- **Payment confirmation is invisible.** No bank notifications, no NEFT/RTGS advice, no
  "payment released" emails from any OEM. The only payment traffic is Caltech *chasing*
  ("not yet received payment for invoices 120, 137, 142"). **Implication:** Nila cannot
  auto-detect "paid" from email. The money map's "auto-updates when paid" needs **bank
  statement / Account Aggregator (India Stack)** integration, or manual confirmation. For
  **SDC v1, advancing to `paid` is manual.**
- **The CA workflow.** ~~Invisible to email; happens on WhatsApp / in person.~~
  **Superseded by §13 (round 4).** Round 3 only searched the office accounts. CA traffic
  runs through Kannan's account (`kannancaltech@gmail.com`, already listed in §2 as the
  "GST data source") and is fully visible. The monthly GST cycle, quarterly advance tax,
  annual document chase, and ad-hoc compliance packages are all email-based and
  substantially automatable. See §13.

### 12.2 Purchase-side / GST data that IS in email

- **Porter** sends a **GST-compliant tax invoice** to the Caltech inbox after every
  delivery (~10 in May), each with Caltech's GSTIN as recipient and full HSN +
  IGST/CGST/SGST breakdown. This is exactly the ITC document stream that feeds GSTR-2B.
  Other vendors (refrigerant gas, coil, courier) likely send the same. **Implication:** the
  GST-scanner wedge has **real machine-readable data already arriving by email**; it is
  buildable, not theoretical. Every outbound SDC/invoice Nila sends also becomes structured
  data feeding the same pipeline.

### 12.3 The post-approval visibility gap (money map's core case)

- **Invoice 106:** submitted Nov 24, GRN booked Nov 27, then **80+ days of silence.**
  Caltech only discovered Feb 16 it had been rejected, via Siemens's **iTracer** portal,
  which itself broke in April and needed a helpdesk escalation. **Implication:** Caltech has
  **zero visibility between GRN booking and payment.** Strongest argument for the money map.
  Nila could (best to worst) integrate iTracer if an API exists, parse the portal, or at
  minimum proactively prompt "GRN-booked 60 days ago, no payment, check iTracer."
- **Quote 93/2025-26 (Erode Cancer Centre, Elekta):** work completed Dec 17, quote sent
  Dec 19, **5 reminders** (Jan 5, Feb 2, Mar 4, Mar 13, more) with no response. Work done,
  money never collected. **Implication:** reminder cadence has **no natural stop**; the money
  map needs an **"aged 60+ days: escalate or flag as effectively written off"** tier rather
  than polite reminders forever.

### 12.4 Adjacent workflows to anticipate (design for, do not build in v1)

- **Field service dispatch.** Siemens engineers email urgent service requests (KKT chiller
  pressure, Lucid Himayathnagar, Yashoda Hitech down, Royapettai GH) to the service inbox.
  An operation often **starts as an inbound OEM email**, then becomes quote → PO → invoice.
  Ingesting these would let Nila link the field job to its eventual invoice. The
  `ApprovalRequest`/Operation model should not preclude an upstream "service request" origin.
- **Recurring obligations (PMS / CAMC).** Solomon broadcast a mandatory summer **Preventive
  Maintenance Schedule** to all chiller contractors; Kannan replied "we will do the PMS" with
  no tracking of which sites are done or due. Currently lives in a "Different Date Contract
  Period" spreadsheet. **Implication:** recurring revenue obligations are **scheduled
  operations**, a future entity distinct from one-off invoices.

### 12.5 Positioning context (non-architectural)

- **"Replace the next hire," not "replace your CA."** They tried to hire (Sindhu, who signed
  some emails with Jaimathi's number, appears to have not worked out) and fought a broken
  hiring app (Nithra Jobs). Nila's value is **preventing the need for a fourth person**, a
  stronger pitch to a family that has tried and failed to grow the team.
- **The CA may be a minor player.** With no CA email traffic, the CA likely handles only the
  final monthly filing. Nila's primary user is **automating work the family does themselves
  today**, not displacing a CA gatekeeper.
