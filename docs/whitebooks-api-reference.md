# Whitebooks supplied API reference

Extracted on 18 September 2026 from the locally supplied
`D:\tmp\whitebooks\GST API.postman_collection.zip`.
This describes the supplied files, not the current live API contract.
See [integration notes](whitebooks.md) for observed live behavior and open questions.

## Source files

- `GST api postman collection.json` is actually OpenAPI 3.0.0: 247 paths.
- `WB-GST-API.postman_collection.json` is a Postman collection: 281 requests.
- They overlap but are not interchangeable. Postman has 35 method/path pairs
  missing from OpenAPI, including both notice endpoints. OpenAPI alone has
  `POST /gstr1a/retsubmit`; its presence does not establish live support.
- All 562 Postman response examples are empty: one HTTP 404 and one HTTP 500
  per request. They cannot supply success fixtures or response schemas.

Byte-identical copies are available locally as
`D:\tmp\whitebooks\extracted\whitebooks.openapi.json` and
`D:\tmp\whitebooks\extracted\whitebooks.postman_collection.json`.
`D:\tmp\whitebooks\API-INDEX.md` lists all requests and their query/header names.
Original archives, documents, spreadsheet, and certificate remain in place.

## Authentication and notices

The following query names come from Postman. Each request also has `email`.
All use `GET`, including operations that change a session or send an OTP.

| Path | Additional query names |
| --- | --- |
| `/public/search` | `gstin` |
| `/authentication/otprequest` | None |
| `/authentication/authtoken` | `otp` |
| `/authentication/refreshtoken` | None |
| `/authentication/logout` | None |
| `/authentication/otpforevc` | `gstin`, `pan`, `form_type` |
| `/notices/noticelist` | `gstin`, `date` |
| `/notices/noticedetails` | `gstin`, `refId` |
| `/all/docdwld` | `gstin`, `retperiod`, `id` |

Every request above includes `client_id` and `client_secret` headers.
Except for public taxpayer search, they also include `gst_username`, `state_cd`,
and `ip_address`. All except public search and the initial OTP request include
`txn`. These names match the seven requests currently implemented in Nila.
Logout and filing OTP are additional vendor definitions, not implemented features.

The notice-list description specifies the last 60 days. The detail description
only says lookup by `refId`; it does not resolve which portal notice categories
are covered. The document-download definition supplies request parameters but
no successful response body. Use the live findings in the integration notes for
PDF decoding, transaction reuse, and dates.

## GSTR-1 definitions worth retaining

The Postman `gstr1` group has 30 requests. Reads include summary (`retsum`),
issued documents (`dociss`), B2B/B2CL/B2CS, registered and unregistered credit/debit
notes, exports, nil-rated supplies, HSN summary, advances, adjustments, amendments,
e-commerce sections, and e-invoices. The full local index preserves the exact
parameters for each request.

`PUT /gstr1/retsave` includes a JSON example with `gstin`, `fp`, `gt`, `cur_gt`,
`b2b`, `b2ba`, `b2cl`, `b2cla`, `cdnr`, `cdnra`, `b2cs`, `b2csa`, `exp`, `expa`,
`hsn`, `nil`, `txpd`, `txpda`, `at`, `ata`, `doc_issue`, `cdnur`, and `cdnura`.
This is useful for exploring upload mapping, but is not proof that the example
covers current filing requirements.

Save, reset, and EVC filing requests use headers `gstin` and `ret_period` in
addition to the session headers. Read requests commonly put `gstin` and
`retperiod` in the query instead; preserve the spelling and location.
`POST /gstr1/reset` has a JSON example with `gstin` and `ret_period`.
`POST /gstr1/retevcfile` supplies `email`, `pan`, and `evcotp` in the query and
has no raw JSON body in the collection. None of these writes were called as
part of extraction.
