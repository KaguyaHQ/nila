# Whitebooks GST integration

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
Sessions use `Nila.EncryptedMap`; OTPs are never saved. The screen conservatively
requires another OTP after the documented six-hour session window. Automated
refresh and scheduled checks are not enabled.

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

## Verified and pending

Production taxpayer lookup succeeded for active and suspended taxpayers on
18 September 2026. An OTP request also succeeded for the suspended taxpayer;
the response has top-level `status_cd`, `status_desc`, and `txn` fields. OTP
verification succeeded with `status_cd` and `status_desc`; it did not issue a
replacement transaction. Notice calls using the original transaction were accepted.
Adapter tests verify request construction and error handling; their response
bodies are synthetic.

Populated list and detail responses have now been inspected for an active
taxpayer (see below). Session expiry and refresh behavior remain unverified live.
Do not infer an empty notice list from an unfamiliar response.

Live notice calls returned nested errors with `error.errorCode` and
`error.errorMessage`. `NOTC_010` means "No Records Found."; `NOTC_005` rejects a
date outside the past 60 days. Both today and a date within that window returned
no records for the tested taxpayer. This does not establish that the taxpayer
has no historical notices or that every portal notice category is covered.

Previously saved notices must not be deleted or marked closed when they
disappear from a later list response.

## Portal notices missing from API responses

The taxpayer supplied portal evidence of a Cancellation SCN dated 21 August
2026 and return-defaulter notices dated 24 June and 25 May 2026. A list request
dated 21 August still returned `NOTC_010`. Direct detail requests for both
return-defaulter reference numbers returned `status_cd: "1"` with this data:

```json
{"dueDateOfReply":"","maindocs":[],"suppdocs":[],"taxPeriod":{}}
```

This is not a usable notice detail, despite the success code. Confirm with
Whitebooks whether these notice categories are supported and whether `refId`
accepts the portal reference number or requires an ID from the notice list.
The supplied cancellation document is FORM GST REG-03 seeking clarification
on a cancellation application, issued 21 August 2026 with a reply date of
2 September 2026. Its direct reference lookup also returned the same empty
success payload. All three known portal notices therefore remain unavailable
through the tested calls. Do not claim API coverage of these portal notices
from these results.

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
returned `NOTC_011` ("Invalid Reference Id."). Supported notice categories and
order coverage still require provider confirmation. Comparing two taxpayers with
different notice categories does not isolate suspension as the cause of the
earlier empty responses.
