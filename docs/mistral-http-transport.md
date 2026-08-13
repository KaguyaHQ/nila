# Mistral HTTP Transport Investigation

> **Status:** transport split implemented and verified in the working tree
> **Investigated:** 2026-08-12
> **Implemented:** Req/Hackney unpooled HTTP/1 for documents; pure HTTP/2 Finch for chat
> **Superseded mitigation:** dedicated Finch HTTP/1 pool with `conn_max_idle_time: 30_000`

This is the durable record of why Nila's document import appeared to restart, what
the network investigation proved, what it did not prove, and which HTTP design we
intend to use. Read this before changing Req, Finch, Hackney, the Mistral provider,
or GST extraction retry behaviour.

The short version is:

- A Mistral OCR request was sent through a Finch HTTP/1 connection that had been
  idle for about 40 minutes. No response packets came back on that path. The local
  TCP stack retransmitted and eventually reset the connection; Req returned
  `:closed`.
- The same PDF succeeded through a fresh connection. This isolates the observed
  failure to connection/path reuse, not invalid PDF content.
- Expiring old Finch connections after 30 seconds removed that particular
  40-minute reuse, but a later real import failed once on Finch pool checkout and
  succeeded on the Oban retry. The mitigation therefore changed the failure mode;
  it did not establish the reliability boundary we want.
- OCR is one sparse, large, paid request. It does not benefit materially from
  connection reuse. The clearest document transport is an explicit unpooled
  HTTP/1 request (`Hackney pool: false`) behind a narrow Req adapter.
- The OpenAI-compatible text path is different: discovery makes up to four concurrent calls and
  invoice extraction makes up to eight concurrent calls. Pure HTTP/2 is a good fit
  for that fan-out and has been tested successfully with Mistral.
- `retry: false` prevents only Req-level replay. The pipeline and Oban can still
  repeat OCR. That replay is visible and auditable, but can repeat provider cost.

## User-visible symptom

An import initially looked like normal progress:

```text
Reading the bills
8 of 15 pages read
```

It then returned to a loading state, sometimes displayed an incomplete-page retry,
and later succeeded. Before the retry UX was added, the worker-level replay was
invisible. The apparent reset was:

```text
Oban attempt 1
  OCR/transcription or a later provider call fails

Oban schedules attempt 2
  the extraction pipeline starts from the beginning
  page progress honestly returns to zero

attempt 2 succeeds
```

The shipped UX now distinguishes these states:

```text
Processing interrupted — retrying (2 of 3)
Reading again — attempt 2 of 3
```

That UX did not cause provider failures. It exposed retries that were already
happening. `DumpWorker` has `max_attempts: 3`; intermediate failures remain Oban
errors, while the LiveView preserves prior progress during backoff and labels the
new attempt.

## The first captured failure

The application log recorded a transcription attempt failing with:

```text
{:mistral_ocr_request_failed, %Req.TransportError{reason: :closed}}
```

The pipeline then emitted:

```text
segmented_extraction.transcription_retry
```

and immediately opened another extraction-attempt row. This was the pipeline's
single internal OCR retry, still within worker attempt 1.

The investigation used real PDFs from:

```text
/Users/vasanthk/.cache/nila/eval-corpus/caltech/
```

including:

```text
2025-05/purchase-part1.pdf
2025-10/sales.pdf
2026-06/sales.pdf
```

The same document frequently succeeded when sent again. That was initially
confusing because Mistral may cache identical OCR work, but a later packet capture
provided a transport-level explanation for at least one failure.

## What the packet capture proved

For the failing request:

1. Finch checked out an HTTP/1 connection that had been idle for roughly 40
   minutes and 36 seconds.
2. Nila wrote request bytes to the connection.
3. No packets or acknowledgements came back from the remote path for that request.
4. The local TCP stack retransmitted.
5. The local machine eventually sent a reset and Req surfaced `:closed`.
6. An identical request through a fresh pool/connection succeeded promptly.

This proves that the reused connection or its network path was unusable while a
fresh connection worked.

It does **not** prove that Mistral deliberately closed the connection. A server,
load balancer, NAT, firewall, Wi-Fi transition, sleeping laptop, or another network
middlebox can silently discard one side of an idle TCP connection. The capture saw
no remote close packet during the failing exchange. The honest diagnosis is a
stale or half-dead reused HTTP/1 path, not "Mistral closed it after N seconds."

This matches a known Finch HTTP/1 failure class: a pooled connection can appear
usable locally after the remote path has forgotten it, and the next checkout only
discovers the problem when a request is written.

## Dependency upgrade: correlation, not demonstrated cause

The failures became noticeable after these dependency changes:

```text
Req    0.5.18 → 0.7.2
Finch  0.22   → 0.23
Mint   1.8    → 1.9.3
```

We did not reproduce the same manufactured half-dead connection under both old and
new dependency sets. Therefore we have not demonstrated that the upgrade caused a
regression.

Relevant history:

- Reports of Finch HTTP/1 `:closed` errors on reused stale connections predate
  these versions.
- Finch 0.22 changed HTTP/2 readiness registration: only ready H2 pools are routed
  requests. An early request can therefore receive `:pool_not_available` rather
  than being sent to a disconnected pool. This is safer behaviour, not evidence
  that HTTP/1 degraded.
- Finch 0.23 fixed a separate concurrent dynamic-pool startup race.

The defensible conclusion is: an old Finch HTTP/1 pooling footgun was observed
after the upgrade; a change in frequency or manifestation remains possible but
unproven.

## Superseded idle-expiry mitigation and why it was incomplete

Commit `b05ee29` introduced `Nila.Gst.Extraction.MistralFinch`, a dedicated
HTTP/1 Finch pool with:

```elixir
conn_max_idle_time: 30_000
```

Finch checks the idle age during checkout and discards connections older than the
limit. This is an intentional Finch mechanism and a reasonable mitigation for the
captured 40-minute socket.

It is not a hard fresh-connection policy. It still uses a pool, and it introduced
another lifecycle edge in the observed workload. A later May 2025 purchase import
failed on worker attempt 1 after about five seconds with Finch reporting that it
could not provide a connection before the pool checkout timeout. No other GST
extraction attempt overlapped. Oban attempt 2 then completed OCR in about four
seconds and the import succeeded.

The state before the final transport split was:

```text
old behaviour:
  occasionally select a very old half-dead socket → :closed after a long wait

30-second expiry mitigation:
  prevents that old-socket checkout
  but has still produced a pool checkout failure on a real import
```

Do not reintroduce or describe that mitigation as having solved the problem
completely. The implementation now removes document operations from connection
pooling instead.

## The extraction workloads are not the same

The production pipeline deliberately separates pixels from interpretation:

```text
transcribe
  one /v1/ocr call for the PDF
  → text for every physical page

discover
  one /v1/chat/completions call per page
  → at most 4 calls concurrently
  → page labels and bill boundaries

extract
  one /v1/chat/completions call per invoice segment
  → at most 8 calls concurrently
  → structured, grounded invoice
```

A 15-page packet with 12 invoices can therefore make approximately:

```text
1 OCR request
15 page-label chat requests
12 invoice-extraction chat requests
```

The chat calls operate on cached transcription text. They do not OCR each physical
page again. This distinction drives the transport decision.

### Document operations

Document operations include:

- `POST /v1/ocr`
- for large inputs, `POST /v1/files`
- `GET /v1/files/:id/url`
- best-effort `DELETE /v1/files/:id`

They are sparse, large, relatively slow, and either directly billed or part of a
billed operation. Saving a TCP/TLS handshake is irrelevant beside a multi-second
OCR. Reusing an idle socket has negative value if one zombie costs tens of seconds
and a failed job.

### Chat operations

Chat calls are smaller, independent, concurrent, and have no external business
side effect. Repeating one can cost tokens, but cannot duplicate an email, consume
an OAuth authorization code, or commit accounting state. Multiplexing is useful
because the application actually has concurrent fan-out, not because "AI should
use HTTP/2."

## Transport experiments

### Fresh HTTP/1

The same real PDF that failed on a long-idle connection succeeded through a fresh
HTTP/1 pool. A separate `Connection: close` experiment sent two consecutive
Mistral requests and observed a new connect event for each, with no
`reused_connection` event.

This proves the normal completed-request path. It does not make
`Connection: close` a hard pre-request primitive: Finch checks out a connection
before sending request headers. If a dedicated pool already contains an old
socket, the request can still be sent on it; the header says not to retain the
connection **after** that exchange.

A dedicated pool on which every request uses `Connection: close` should therefore
produce effectively fresh connections in steady state, but failure cleanup would
still need deterministic testing.

### Pure HTTP/2

Mistral negotiated `h2` through TLS ALPN. A pure Finch H2 pool successfully sent a
real 573 KB PDF to `/v1/ocr` and received HTTP 200 in about four seconds.

An immediate first request after starting the H2 pool returned:

```text
%Req.HTTPError{protocol: :http2, reason: :pool_not_available}
```

about 13 milliseconds after the call. The next request succeeded. This is the H2
connection becoming ready asynchronously, not an ambiguous in-flight failure: no
connected pool was available to accept the first request.

Req understands H2 readiness errors, but its default `:safe_transient` policy only
retries GET/HEAD. `retry: :transient` extends retries to POST, which is too broad
for paid OCR. A custom callback can narrowly replay only a proven pre-send
readiness error:

```elixir
retry: fn
  _request, %Req.HTTPError{protocol: :http2, reason: :pool_not_available} ->
    {:delay, 200}

  _request, _response_or_error ->
    false
end,
max_retries: 2
```

That callback becomes the entire Req retry policy. It must not silently grow to
include `:closed`, timeouts, HTTP 500, or other failures that may have happened
after transmission.

### Do not use mixed Finch protocols

Do not configure:

```elixir
protocols: [:http1, :http2]
```

Pure HTTP/1 and pure HTTP/2 both handled large POST bodies in testing. Finch's
mixed ALPN mode uses the HTTP/1-style pool without H2 multiplexing and has a known
large-body flow-control failure around the HTTP/2 initial window. Nila's PDFs and
many prompts exceed 64 KB. Choose one pure protocol per pool.

## Retry semantics: three different layers

The word "retry" hides three mechanisms. Treat them separately.

### 1. Req retry

`retry: false` means one HTTP adapter invocation. It prevents an immediate,
invisible HTTP replay by Req. It says nothing about callers.

### 2. Pipeline transcription retry

`Pipeline.attempt_transcription/4` currently retries OCR once for selected
transport failures and HTTP 429/5xx responses. This is visible as:

```text
Pages all did not come back. Asking again.
```

The historical reason is that identical OCR requests have often returned quickly
from Mistral's cache after a slow or lost first response. It still repeats the
provider operation and may repeat cost.

### 3. Oban worker retry

`DumpWorker` allows three attempts. A crash or returned error can restart the
entire extraction pipeline, including OCR. The UX now makes that replay visible,
but visibility does not change network semantics.

The dangerous sequence remains possible:

```text
OCR request leaves Nila
Mistral processes and bills it
response is lost
Nila observes a transport error
pipeline or Oban retries
Mistral processes it again
```

This is acceptable only as an explicit product tradeoff: OCR has no external
business mutation, so the consequence is duplicate provider cost and latency, not
duplicate accounting truth. If Mistral adds an idempotency key for OCR, use it.
The public OCR contract investigated on 2026-08-12 did not document one.

Mistral Files is less tidy. If upload succeeds but its response is lost, Nila does
not know the created file ID, cannot checkpoint or delete it, and a retry can create
an orphan duplicate. Checkpointing helps only after the ID reaches Nila. Provider
idempotency or a reliable lookup mechanism is required to eliminate that ambiguity.

## Alternatives considered

### Keep Finch HTTP/1 with finite idle time

Benefits:

- already shipped;
- native Finch lifecycle control;
- minimal code.

Rejected as the final boundary because a sparse document path does not need reuse,
and a real import still experienced a pool checkout failure after the change.

### Dedicated Finch HTTP/1 plus `Connection: close`

Benefits:

- keeps the current Req/Finch/Mint stack;
- demonstrated two connects and zero reuse on consecutive successful requests;
- handshake overhead is negligible.

Still a valid fallback. It is weaker conceptually than an explicit no-pool
operation because the request header controls what happens after the exchange, not
which resource Finch checks out before it.

### Pure Finch HTTP/2 for documents and chat

Benefits:

- supported by Mistral and verified with a real PDF;
- avoids the specific Finch HTTP/1 pool architecture;
- excellent for concurrent chat.

Not preferred for OCR solely as a reliability fix. It maintains a long-lived
shared connection and requires narrow startup/readiness handling. It also cannot
eliminate ambiguous failures after request transmission.

### Hackney or HTTPoison for everything

Benefits:

- Hackney exposes an explicit `pool: false` one-off request;
- Nila is small enough that a migration is technically feasible.

Rejected as a global migration. HTTPoison is another high-level stack over Hackney,
not a guarantee against network ambiguity. Hackney 4 has its own pooling,
protocol-selection, streaming, timeout, telemetry, and recently changed connection
lifecycle. Global replacement would touch OAuth, mail, Meta, Resend, assistant SSE,
and storage without evidence that those paths are failing.

### Direct Mint

Rejected. Mint is intentionally low-level. Nila would become responsible for
connection ownership, message receipt, timeouts, closing, and H2 state. That adds
networking code in the name of reliability.

## Implemented design

### Mistral documents: Req with a narrow Hackney adapter

Req remains the application-facing API. `MistralDocumentAdapter` is the small
adapter used by Mistral document operations and forces:

```text
HTTP/1 only
Hackney pool: false
Req retry: false
explicit connect/send/receive timeouts
```

The adapter is not a new general HTTP abstraction. It supports only what Mistral
documents use:

- buffered GET, POST, and DELETE;
- binary, JSON, and multipart request bodies after Req has encoded them;
- buffered responses;
- normalized results as `Req.Response` and `Req.TransportError`;
- document-request telemetry;
- no streaming mode.

Reject unsupported options explicitly. Do not silently approximate Finch
semantics.

Why this is now preferred over `Connection: close`: `pool: false` states the
required property at the client boundary. There is no pool from which an old
document socket can be selected.

### OpenAI-compatible text: dedicated Finch

`OpenAICompatibleChatFinch` configures the selected text-provider origin for one
explicit pure protocol. Mistral and Z.ai use HTTP/2; Tencent TokenHub currently
negotiates HTTP/1.1 and is configured with `GST_TEXT_HTTP_PROTOCOL=http1`:

```elixir
protocols: [:http2]
```

It uses the default H2 `count` of one because one connection can multiplex streams.
Increase the count only if telemetry shows one shard is a limit. A finite idle ping may help
keep the path active and detect some failures, but must not be described as making
the network immortal.

Chat retry policy should be operation-aware:

- HTTP 429 is expected under page/segment fan-out and can back off;
- `:pool_not_available` is safe to retry because no ready pool accepted the call;
- H2 `:unprocessed` is normally replayable by protocol;
- avoid casually adding ambiguous timeouts/connection closures merely because the
  call has no business side effect—the replay still costs tokens.

### Other integrations: no global migration

Gmail, Microsoft, Meta/WhatsApp, Resend, assistant providers, and storage stay on
their existing Req paths until evidence warrants provider-specific changes.
Different origins already have separate Finch pools, so the Mistral socket cannot
poison a Google or Meta pool.

The general policy is:

| Operation | Policy |
| --- | --- |
| GET/HEAD | Normal pooling; Req's safe transient retry is usually appropriate |
| OAuth token POST | No automatic replay; a code may have been consumed despite a lost response |
| Send email/message | No automatic replay without provider idempotency or reconciliation |
| Sparse paid document POST | Prefer an explicit one-off connection; accept visible job replay cost |
| Concurrent, side-effect-free calls | Pure H2 when the origin is tested and supports it |

Connection management cannot solve ambiguous application replay. OAuth, mail, and
messaging require provider idempotency keys, transaction identifiers,
read-after-write reconciliation, or manual retry policy—not merely a different
socket pool.

## Verification completed and remaining fault work

Completed on 2026-08-12:

- a local TCP test made two successful adapter calls and observed two separate
  accepted connections;
- a local failure test dropped the first exchange and proved the next adapter call
  opened another connection and succeeded;
- adapter tests assert `pool: false`, pure HTTP/1, explicit timeouts, buffered-only
  behavior, and telemetry that omits document content;
- retry-policy tests prove chat retries H2 pre-send/readiness errors and rejects
  ambiguous `:closed` and timeout replays;
- the complete test suite passed: 1,203 tests, 2 excluded;
- a real unpooled OCR call on `caltech/2025-05/purchase-part1.pdf` returned HTTP
  200 with three pages in 2.9 seconds;
- a real pure-H2 chat call encountered `:pool_not_available` during cold startup,
  retried after 200ms, and returned HTTP 200. A preceding 50ms experiment failed,
  which is why the implemented readiness delay is 200ms rather than the initial
  proposal.

Further hardening should use a deterministic local fault harness rather than paying
for ten OCR calls with hour-long sleeps. It should emulate the Mistral origin
through a TCP/TLS-aware proxy or controlled test server and cover:

1. TLS interruption while sending a large request body;
2. a response lost after the server accepts the request;
3. a black-holed connection with no ACK or close;
4. H2 reconnection after an established pool loses its transport;
5. concurrent H2 chat requests with bodies above and below 64 KB;
6. the >20 MB Mistral Files upload/sign/delete path against the real provider.

For the document adapter, telemetry must show a new TCP/TLS connect for every
adapter call and no pool checkout/reuse. For chat, telemetry must show pure H2 and
successful multiplexing.

The representative inline PDF and one H2 call are covered. The large Files path,
page-label fan-out, and segment-extraction fan-out remain useful integration smoke
tests before a production deployment.

Do not call the work complete merely because the happy path returns HTTP 200.

## Telemetry fields to preserve

Record enough context to distinguish transport, provider, pipeline, and job retries:

```text
provider and origin
HTTP method and path template
protocol
connection policy (unpooled / H1 / H2)
fresh versus reused connection, where applicable
connection idle age, where applicable
connect duration
pool checkout duration, where applicable
send duration
time to response headers
total receive duration
error module and reason
provider request ID
GST dump ID
extraction stage
pipeline transcription try number
Oban worker attempt and maximum attempts
```

Never log authorization headers, document bytes, base64 request bodies, signed file
URLs, or extracted invoice contents in transport telemetry.

## Source map

Current relevant code:

- `lib/nila/gst/extraction/mistral_document_adapter.ex` — unpooled pure-H1 document adapter
- `lib/nila/gst/extraction/openai_compatible_chat_finch.ex` — text-provider pool
- `lib/nila/gst/extraction/providers/mistral.ex` — OCR and Files API calls
- `lib/nila/gst/extraction/providers/openai_compatible_chat.ex` — concurrent text/JSON calls
- `lib/nila/gst/extraction/pipeline.ex` — OCR, internal transcription retry, discovery, extraction
- `lib/nila/gst/extraction/discovery/page_labels.ex` — per-page concurrency (4)
- `lib/nila/gst/extraction/segmented.ex` — per-segment concurrency (8)
- `lib/nila/gst/intake/dump_worker.ex` — audited stages and Oban attempts
- `lib/nila_web/live/gst/upload_live.ex` — visible worker-retry state

Related record:

- `docs/ocr-extraction.md` — extraction correctness, latency, caching, and the
  segment-then-extract design. That document explains semantic extraction quality;
  this one explains HTTP transport and replay.

## Decision summary for the next agent

Do not restart the debate from "Finch versus Hackney" as a universal choice. The
decision is workload-specific:

```text
Mistral document bytes
  → explicit one-off HTTP/1 transport
  → narrow Req/Hackney adapter with pool:false
  → no Req replay
  → pipeline/Oban replay remains visible and may repeat cost

OpenAI-compatible text over cached OCR
  → selected provider/model from runtime config
  → explicit pure HTTP/2 or HTTP/1 from provider config
  → narrowly defined retry conditions

all other integrations
  → unchanged until their own evidence says otherwise
```

The former 30-second Finch idle limit has been removed. It is historical evidence,
not the architecture to restore.
