# Whitebooks GST integration

## Handoff: notice discovery is the remaining product question

Last updated: 19 September 2026. Read this before running more live probes.
**Retrieving a known reference is not proof that the API will discover a new notice.**

| Portal item | Automatic list discovery | Direct details | PDF retrieval |
| --- | --- | --- | --- |
| July adjudication reminder | Verified | Verified | Downloaded and opened |
| June DRC-01 / SCN | Outside tested 60-day window | Verified | Not established by our tests |
| March 2025 ASMT-10 | Outside tested 60-day window | Verified | Two PDFs decoded; not visually inspected |
| August Section 73 order / DRC-07 | Missing despite being inside the window | `NOTC_011` | Not retrieved through Whitebooks |
| REG-03 cancellation clarification | Not returned in tested lookup | Empty, unusable success | Not retrieved |
| Two return-defaulter notices | Not established | Empty, unusable success | Not retrieved |
| Enforcement | Support says supported; not tested | Not tested | Not tested |

These are results for specific references, not guarantees for entire categories.
The list rejects dates outside the past 60 days; direct details can retrieve older
references. We have no verified alternative API for discovering those old references.
Do not restrict imports to a fixed category list: ASMT-10 direct retrieval also
worked. Automatic discovery coverage must be tested separately. The screen
describes the 60-day check window and warns that some notices and orders may
only appear on the GST portal.

### Breeze Tech outcome: known from user-supplied PDFs, not the API

Portal screenshots link June's SCN, July's reminder and August's order to case
`AD330626028784V`, covering April 2022 to March 2023. Order reference
`ZD330826099678I` is a Section 73 adjudication order with a DRC-07 summary.
The detailed order concludes that tax and interest were paid, no penalty is
payable, nothing remains recoverable, and the proceedings are concluded. The
DRC-07 demand totals are zero. Do not infer an outstanding demand from the
portal label "Order for creation of demand issued" or the old reminder.

Source PDFs supplied by the user and text-read on 19 September 2026:
`C:\Users\benze\Downloads\DRC 07 BREEZE TECH 2022-23.pdf` (conclusion on page 4;
zero revenue table on page 5), and
`C:\Users\benze\Downloads\DRC07_ORDER_ZD330826099678I_20260812063145-1.pdf`
(order reference on page 1; DRC-07 and zero demand on pages 4-5).
These local files may not exist on another machine. They were not imported into Nila.
The order/notice distinction may explain the API rejection, but no separate order
endpoint has been established. Ask Whitebooks for a working request or confirmation
that retrieval is unsupported, without assuming an undocumented endpoint exists.

### Product boundary and next evidence

Current implementation fetches and saves notices, displays client check status,
and downloads PDFs on demand. `Notices.fetch_by_reference/3` saves a supplied
reference through the core library; there is no screen control for it yet.
June and ASMT-10 diagnostic lookups were not saved to the dashboard. Session
refresh is implemented; it is separate from automatic notice polling, which is not.

Manual order/REG upload, extraction, human-confirmed outcomes, assignments and
follow-ups were discussed as a possible workflow, not implemented or approved as
the next build. Uploads can fill document gaps but cannot solve missing discovery.
Do not claim "80% monitoring coverage", full notice management, or announce that
an order was issued without evidence of that event.

Next useful validation: compare regular list results against portal entries for a
small authorized set of GSTINs, including a known ASMT-10 issued within 60 days.
Measure new-notice discovery, dates, attachments and subsequent case updates.
No Whitebooks-seeded sandbox notice fixture has been obtained; automated fixtures
are synthetic. Avoid repeating live OTP/PDF probes without a specific unanswered
question, since provider calls may be billable.

`Nila.Integrations.Whitebooks` calls the production API at
`https://api.whitebooks.in` using Req. Configure these server-side values in the
local ignored `.env`, or the production environment:

```dotenv
WHITEBOOKS_CLIENT_ID=
WHITEBOOKS_CLIENT_SECRET=
WHITEBOOKS_EMAIL=
WHITEBOOKS_IP_ADDRESS=
```

The adapter supports taxpayer lookup, OTP request, OTP verification, session
refresh, notice list, notice details, and document download. Authentication calls take an account
map with `:gstin`, `:username`, and `:ip_address`; verification, refresh, and
notice calls also require `:txn` from Whitebooks authentication.

Calls return `{:ok, provider_envelope}` only when `status_cd` is `"1"`.
Errors distinguish missing configuration, invalid account fields, HTTP failure,
provider failure, transport failure, and unexpected responses. Provider errors
retain only an error code to avoid exposing echoed secrets. Requests do not
follow redirects or retry automatically, including OTP requests sent as GETs.
Never log authentication envelopes or OTP request URLs.

## Agent usage: use the core modules

Use `Nila.Gst.Portal` for shared login and `Nila.Notices` for saved notices and
PDF decoding. Do not copy HTTP calls, decrypt sessions, or keep separate login
files in probes. The adapter is for integration internals and isolated tests.

For a local script, run `mix run --no-start tmp/check_notice.exs`. This starts
only the dependencies needed below, avoiding application background workers:

```elixir
Application.ensure_all_started(:req)
Application.ensure_all_started(:ecto_sql)
{:ok, _} = Nila.Repo.start_link()

user_id = System.fetch_env!("NILA_USER_ID") |> String.to_integer()
org_id = System.fetch_env!("NILA_ORG_ID") |> String.to_integer()
client_id = System.fetch_env!("NILA_CLIENT_ID") |> String.to_integer()
scope = Nila.Accounts.Scope.for_user(Nila.Repo.get!(Nila.Accounts.User, user_id))
# Scope.for_user selects the first membership. Never silently use the wrong firm.
true = scope.current_org.id == org_id

{:ok, notice} = Nila.Notices.fetch_by_reference(
  scope, client_id, System.fetch_env!("GST_NOTICE_REFERENCE")
)
IO.inspect(%{id: notice.id, reference: notice.reference, issued_on: notice.issued_on})

# Download only the required attachment; each download makes another API call.
{:ok, pdf} = Nila.Notices.download(org_id, notice.id, 0)
IO.puts("Validated PDF: #{byte_size(pdf)} bytes")
```

`fetch_by_reference/3` requires permission to edit records. It validates and
upserts one notice, including references older than the list window. It does not
mark the whole client's notice list as checked or clear a previous check error.
It preserves earlier list evidence. PDFs are returned as bytes, not archived;
use `Nila.Storage` if retaining a document is part of the authorized task.

If the session is missing or expired, connect through the app's GST connection
dialog first. For a console flow, use `iex -S mix run --no-start`, initialize the
same dependencies and scope above, and keep the challenge in that process:

```elixir
{:ok, challenge} = Nila.Gst.Portal.request_otp(
  scope, client_id, System.fetch_env!("GST_USERNAME")
); :ok
otp = IO.gets("Newest GST OTP: ") |> String.trim(); :ok
{:ok, _} = Nila.Gst.Portal.verify_otp(scope, challenge, otp); :ok
otp = nil; challenge = nil; :ok
```

The prompt echoes input; use a private console. Never put OTPs in source files,
shell command arguments, logs, or committed fixtures. Verification saves the
encrypted session for the app and later calls to reuse. Do not request another
OTP for each document. Use Req.Test for automated tests; live checks consume
provider requests, and billable quota rules have not been confirmed.

## Supplied API material

The vendor ZIP inspected on 18 September 2026 contains two different references:
`GST api postman collection.json` is OpenAPI 3.0.0 with 247 paths;
`WB-GST-API.postman_collection.json` is a Postman collection with 281 requests.
The notice endpoints appear only in Postman. OpenAPI alone includes
`POST /gstr1a/retsubmit`, so neither file is a complete substitute for the other.
All 562 Postman response examples are empty HTTP 404/500 responses; they cannot
establish successful response shapes or live endpoint support. Keep the original
files and full endpoint inventory outside the repository.

Authentication, taxpayer search, notices, and document download use `GET`,
including OTP requests that have side effects. All take `email` in the query and
`client_id`/`client_secret` headers. Client-account calls also use `gst_username`,
`state_cd`, and `ip_address`; after the initial OTP request they require `txn`.
Public taxpayer search does not require client-account headers or an OTP session.

The collection also includes GSTR-1 reads and sample save, reset, and EVC filing
requests. `PUT /gstr1/retsave` supplies an example return body. These writes use
`gstin` and `ret_period` headers; reads commonly use `gstin` and `retperiod` query
parameters instead. Preserve those spellings and locations if implementing them.
The examples are reference material, not verified Nila filing support or proof of
current filing requirements.

## Screen and storage

Open `/notices` or use **Firm → Notices**. Expand **Client checks** to connect a
client using the portal username and OTP, then check notices. This section stays
firm-wide when the notice list is filtered. It shows each client's connection
state, last successful check, and next action. Owners manage
connections; operators can check notices; viewers can read saved notices and PDFs.
`WHITEBOOKS_IP_ADDRESS` is the server's public IP, sent in Whitebooks' required
header. The local setup uses the IP verified during the live API checks.

GST login belongs to `Nila.Gst.Portal`. The follow-up migration renames
`gst_notice_connections` to `gst_portal_connections`, preserving encrypted sessions,
and moves notice check times/errors into `gst_notice_checks`. Notices remain in
`gst_notices`.
Sessions use `Nila.EncryptedMap`; OTPs are never saved. Whitebooks documents a
six-hour token window. The existing Oban cron runs a refresh sweep every 15 minutes,
queuing connections whose last successful authentication/refresh is at least five
hours old. Reads also refresh on demand, including after a missed background run.
The server must be running for scheduled refreshes; changes to the cron config
require a restart. Scheduled notice checks are not enabled.

`authorized_at` retains the OTP login time. The encrypted credentials map holds
`refreshed_at` and, only after a provider authentication rejection,
`reauth_required`. A successful refresh retains `txn` when none is returned or
saves its replacement. Refreshes serialize per connection to prevent duplicate
refresh calls and stale writes. Transport errors and unknown provider failures
remain retryable without marking the taxpayer's authorization expired.

`RET11407` (invalid auth token), `RET11408` (invalid transaction), and the observed
`WB_ERR_9503` trigger one refresh and one read retry. A rejection from refresh,
or the same class of failure after retry, requires another OTP. Other errors do
not establish that a new OTP is required. There is no hard-coded 30-day cutoff;
Whitebooks' outer authorization lifetime remains unverified.

Manual checks run on the existing Oban `workflows` queue. Repeated checks update
the same client/GSTIN/reference record. A failed or malformed response preserves
saved notices and the last successful check time. Empty lists never delete records.
PDFs are fetched on demand through an organization-scoped controller, validated
as PDF bytes and sent with private/no-store headers; they require a usable GST
session. PDFs are not archived in this first version.

## Sales taxpayer checks

`Portal.lookup_taxpayer/1` validates the GSTIN locally and reuses a successful
lookup for 30 days. `gst_taxpayer_lookups` holds one latest successful row per
GSTIN: legal/trade names, registration status, provider, check time, and the
allowlisted taxpayer response fields. Public taxpayer facts are shared across
firms; client usernames and sessions are always client/organization scoped.
Failures remain Oban job errors and never replace the saved success.

Sales extraction, source corrections, and opening a sales review queue missing
or stale GSTINs on Oban's existing workflows queue. Repeated invoice GSTINs share
a job within the firm; jobs retry up to three times and suppress repeated attempts
for one hour. Validators and exports read saved facts without making HTTP calls.

Sales compares both legal and trade names, ignoring case, punctuation, spaces,
and Private/Pvt or Limited/Ltd variants. Other differences and non-active status
require review. Missing or stale evidence appears as not checked, never as an
invalid GSTIN. The check date is shown; current status is not treated as proof of
registration status on the invoice date. Invoice facts are never rewritten.

These checks use the existing invoice review and confirmation flow. Confirmations
are tied to the compared facts, so changed names/status cannot inherit an old
confirmation. A newly found exception reopens an affected unfiled review; filed
month snapshots remain unchanged. The cache itself has no version history.

## GSTR-2B downloads

Open **GSTR-2B** (`/gst/2b`), choose a client and return month, and fetch the
statement using the client's existing GST session. An expired or missing session
opens the shared GST connection dialog in place. Verification automatically
continues the chosen client's fetch for the chosen month. Notices uses the same
dialog and resumes its check after verification. Closing and reopening the dialog
on the same page preserves an unexpired OTP request; OTP values are never saved.
Client pages have a **GST portal access** section for reconnecting, changing the
username through verification, and disconnecting. Disconnecting retains saved
statements and notices. Owners/admins manage connections; operators can fetch
with an existing session; viewers can
download saved statements. Oban handles the fetch and deduplicates requests in
progress. A failed refresh leaves the previous successful document available.

`GET /gstr2b/all` takes `gstin` and `rtnprd` (`MMYYYY`). A live July 2026 request
for Breeze Tech succeeded on 18 September 2026. Its successful `data` contains
the portal document `{chksum, data}`, with GSTIN, return month, generation date,
summaries and `docdata.b2b`. We validate the GSTIN, month and document structure
before saving it. Provider errors and file manifests are not statements.
Multi-file downloads are not implemented; unrecognized responses leave the
previous download intact.

`gst_portal_statements` retains the latest successful portal JSON and fetch time
per client/GSTIN/month in Postgres. Downloads preserve its JSON values (formatting
may differ), exclude the provider status/authentication envelope, and use a
firm-scoped authenticated route with `private, no-store`. Fetching does not import
purchases, reconcile them, generate a new 2B, or submit a return.

## Verified and pending

Production taxpayer lookup succeeded for active and suspended taxpayers on
18 September 2026. An OTP request also succeeded for the suspended taxpayer;
the response has top-level `status_cd`, `status_desc`, and `txn` fields. OTP
verification succeeded with `status_cd` and `status_desc`; it did not issue a
replacement transaction. Notice calls using the original transaction were accepted.
Adapter tests verify request construction and error handling; their response
bodies are synthetic.

Populated list and detail responses have now been inspected for an active
taxpayer (see below). On 19 September 2026, refresh succeeded for both the fresh
probe session and the previous day's saved session. The response contained
`status_cd: "1"` and `status_desc`, with no new `txn`. A subsequent July reminder
lookup using the previous day's original `txn` succeeded. This establishes that
six hours of local age alone does not require another OTP, but does not establish
the outer authorization lifetime or every provider rejection code.
Do not infer an empty notice list from an unfamiliar response.

Live notice calls returned nested errors with `error.errorCode` and
`error.errorMessage`. `NOTC_010` means "No Records Found."; `NOTC_005` rejects a
date outside the past 60 days. Both today and a date within that window returned
no records for the tested taxpayer. This does not establish that the taxpayer
has no historical notices or that every portal notice category is covered.

Previously saved notices must not be deleted or marked closed when they
disappear from a later list response.

## Observed notice retrieval coverage

On 19 September 2026, a production lookup of ASMT-10 reference
`ZD330325083017M` returned its issue date (13 March 2025), reply date
(14 April 2025), and two attachments. Both attachments downloaded and decoded
to PDF-signature bytes (40,894 and 324,694 bytes); they were not visually
inspected in that probe. This establishes retrieval for that reference, not
support for every scrutiny notice. Automatic discovery of recent ASMT-10s
through the list endpoint remains unverified.

Category support does not establish that every notice or order in those
categories is returned. The missing August determination order below remains
unresolved. Empty success payloads are still rejected as unusable notice details.

## Portal notices missing from API responses

The taxpayer supplied portal evidence of a Cancellation SCN dated 21 August
2026 and return-defaulter notices dated 24 June and 25 May 2026. A list request
dated 21 August still returned `NOTC_010`. Direct detail requests for both
return-defaulter reference numbers returned `status_cd: "1"` with this data:

```json
{"dueDateOfReply":"","maindocs":[],"suppdocs":[],"taxPeriod":{}}
```

This is not a usable notice detail, despite the success code. These results do
not establish a category-wide exclusion or explain why the references failed.
The supplied cancellation document is FORM GST REG-03 seeking clarification
on a cancellation application, issued 21 August 2026 with a reply date of
2 September 2026. Its direct reference lookup also returned the same empty
success payload. All three known portal notices therefore remain unavailable
through the tested calls. Do not claim API coverage of these portal notices
from these results, or attribute the failures to the taxpayer's suspended
registration without further evidence.

## Successful active-taxpayer notice responses

OTP authentication and notice retrieval succeeded for an active taxpayer on
18 September 2026. A list request starting 59 days before today returned a July
reminder. The populated response is `data.notices`, an array with `refId`, `arn`,
`dateOfIssue`, `dateOfRespond`, `moduleCd`, and `alertCd`. Dates use DD/MM/YYYY;
the list's `dateOfRespond` was `"NA"` even though the detail supplied a reply date.

The reminder detail returned `data.arn`, `dateOfIssue`, `dueDateOfReply`,
`noticeType`, `maindocs`, `suppdocs`, and `taxPeriod`. A June SCN also returned
details when requested by its printed reference, despite being outside the list
window. Its tax period had `fromMonth`, `fromYear`, `toMonth`, and `toYear`.

Document entries contain `dcupdtls` with `id`, `docName`, `ct`, `hash`, and `ty`.
These are document references, not PDF bytes or download URLs. The reminder PDF
was successfully downloaded through `/all/docdwld`, using its document ID and
issue month as `retperiod`. The response contains base64 in `data.data` and
`data.ct: "application/pdf"`. Its 38,772 decoded bytes have the PDF signature and
were opened through the application in a browser. The metadata `hash` does not
match SHA-256 of these downloaded bytes, so its meaning is not assumed.
No reply/submission or closure status was present in the notice responses;
an elapsed reply date alone must not be presented as an outstanding task.

A known August determination order was absent from the same list and its detail
returned `NOTC_011` ("Invalid Reference Id."). Although support has now confirmed
the two supported categories, this missing order still needs an explanation.
Comparing two taxpayers with
different notice categories does not isolate suspension as the cause of the
earlier empty responses.
