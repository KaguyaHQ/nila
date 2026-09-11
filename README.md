# Nila

Nila is the AI accountant for Indian CA firms, starting with GST. A Phoenix + LiveView
monolith.

**First product: sales bills → Excel workings for GSTR-1.** Nila prepares the file
a junior would otherwise type and assemble. The accountant resolves exceptions;
the senior checks the working, and the firm retains it as evidence for its filing.

See [the current objective and customer evidence](docs/prd.md#current-objective)
for why this is the first product, and [the sales code guide](lib/nila/gst/sales/README.md)
for how it is organized. Tally, WhatsApp, banking, and purchase workflows also
exist in the repository; they do not define the current product scope.

## Stack

- Phoenix 1.8, LiveView
- Ecto + PostgreSQL (source of truth)
- Oban (extraction and derivation jobs)
- Tailwind CSS, daisyUI token plumbing, and Nila components (see `docs/design/DESIGN.md`)
- Req/Jason for HTTP/JSON
- `Nila.Storage` — local disk in dev/test, private Cloudflare R2 in production

## Local setup

```bash
# dev.exs requires local PostgreSQL on localhost:5432.
mix setup
mix phx.server
```

Open http://localhost:4000.

```bash
mix test
mix ecto.reset
mix precommit
```

## Production object storage

Production uses the private `nila-documents` Cloudflare R2 bucket through the
S3-compatible API. Create an R2 API token with Object Read & Write permission, scope it
only to `nila-documents`, and leave public access and custom domains disabled. Object
Read & Write includes the read, upload, and delete operations Nila needs.

Set these only in the production runtime environment:

```env
R2_ENDPOINT=https://0b6491b35807b48232b57646af4e7eeb.r2.cloudflarestorage.com
R2_BUCKET=nila-documents
R2_ACCESS_KEY_ID=
R2_SECRET_ACCESS_KEY=
```

The normal test suite always uses `Nila.Storage.Local`. To explicitly run the live R2
put/get/metadata/delete smoke test, export the four variables above and run:

```bash
mix test --include r2_integration test/nila/storage/r2_integration_test.exs
```

## WhatsApp provisioning

Configure the Meta webhook as `https://HOST/webhooks/whatsapp` and set
`WHATSAPP_APP_SECRET` and `WHATSAPP_VERIFY_TOKEN` in the runtime environment. Outbound
chasing additionally needs `WHATSAPP_CHASE_TEMPLATE`, `WHATSAPP_COMPLETENESS_TEMPLATE`,
and a 32-byte-or-longer `WHATSAPP_COMPLETENESS_SECRET`.

For self-service onboarding, create a Facebook Login for Business configuration using
Embedded Signup v4 and the Cloud API products. Configure:

```env
WHATSAPP_APP_ID=
WHATSAPP_APP_SECRET=
WHATSAPP_EMBEDDED_SIGNUP_CONFIG_ID=
WHATSAPP_GRAPH_URL=https://graph.facebook.com/v26.0
```

The Connect WhatsApp button appears under Settings → Connectors once the app ID, app
secret, and config ID are present; any customer business may then authorise. Set the
optional `WHATSAPP_EMBEDDED_SIGNUP_ALLOWED_BUSINESS_ID` to pin signup to a single Meta
business during controlled testing, where the person completing signup holds a role on
Nila's Meta app and full control of that business. Leave it unset in production and for
Meta App Review, or the reviewer's own business is rejected. Nila exchanges Meta's short-lived code server-side, verifies the
business/WABA/phone through Graph, subscribes the app to the WABA, registers the number,
and encrypts the resulting BISU token and generated two-step-verification PIN. A local
disconnect erases those credentials and requires Embedded Signup again; it does not
unsubscribe the whole WABA because that subscription may serve multiple phone numbers.
Use Verify readiness for token/phone/subscription checks. Confirm receiving with a
user-initiated message to the connected number; Nila never sends an unsolicited test
message.

The Mix task remains the operator recovery path. Connect or rotate a firm's WhatsApp
Cloud API phone-number ID without putting the access token in command arguments:

```bash
export WHATSAPP_ACCESS_TOKEN="..."
mix nila.whatsapp.connect \
  --org-id 42 \
  --phone-number-id 123456789 \
  --label "Firm WhatsApp"
```

Production releases do not include Mix. With `WHATSAPP_ACCESS_TOKEN` exported in the
operator shell, run:

```bash
bin/nila eval 'IO.inspect(Nila.Release.provision_whatsapp(%{org_id: 42, phone_number_id: "123456789", label: "Firm WhatsApp"}))'
```

The token is stored through `Nila.EncryptedMap`. A phone-number ID may belong to only one
Nila organisation.

## Layout

- `lib/nila/` — business contexts. `gst/` is the core: extraction, recon, flags,
  resolutions, sign-offs, dumps, returns. Plus accounts, orgs, clients, documents,
  workflows, audits, integrations, storage.
- `lib/nila_web/` — LiveViews and web plumbing.
- `docs/` — architecture, decisions, design system, PRD.

## Deliberately not built (yet)

Amendments (filed is immutable; the amendment tables for later periods don't exist),
cross-month ITC carry, QRMP, photo/image intake. Pulled by real usage, not pushed.
