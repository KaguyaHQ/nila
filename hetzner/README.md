# Nila — Hetzner Deployment

Nila runs on the **same Hetzner box as kaguya** (`46.224.237.179`, Nuremberg),
as its own compose project at `/home/deploy/nila`. The **edge-ops** Caddy is the
shared ingress (owns ports 80/443) and reverse-proxies `nila.tax` to Nila's container
over a shared Docker network named `edge`. `nilahq.com` redirects to `nila.tax`.

```
Browser → Cloudflare (TLS + cache) → Caddy (edge-ops stack) ──edge──▶ nila:8080 (Phoenix LiveView)
                                                                       │ internal
                                                                       ▼
                                                                 nila-postgres:5432
```

- **Domain**: `nila.tax`, proxied through Cloudflare. Caddy uses the edge stack's `certs/nila-tax-origin.pem`, whose SANs are `nila.tax` and `*.nila.tax`. `nilahq.com` redirects to `nila.tax`. Email sends from `nila.tax`.
- **Image**: `ghcr.io/kaguyahq/nila`; `.github/workflows/deploy.yml` publishes both `latest` and the commit SHA, while Compose deploys `latest`.
- **DB**: dedicated `postgres:17-alpine` container, private `internal` network, volume `nila_pgdata`.
- **Server files**: `/home/deploy/nila/` (`docker-compose.yml`, `deploy.sh`, `.env`)

All operator commands use the `nila-prod` SSH alias so SSH selects the deploy
user's dedicated key. Configure it once in `~/.ssh/config`:

```sshconfig
Host nila-prod
    HostName 46.224.237.179
    User deploy
    IdentityFile ~/.ssh/hetzner_deploy
    IdentitiesOnly yes
```

Use `ssh nila-prod`, not `ssh deploy@46.224.237.179`; the raw address bypasses
the alias-specific identity and fails unless `-i ~/.ssh/hetzner_deploy` is
supplied explicitly.

---

## One-time bootstrap

Steps 1–4 are manual the first time; after that, pushes to `main` deploy
automatically.

### 1. GitHub repo secrets (KaguyaHQ/nila)

Add the same secrets the kaguya repo uses (Settings → Secrets → Actions):

- `HETZNER_HOST` — `46.224.237.179`
- `HETZNER_SSH_KEY` — the `deploy` user's private SSH key

### 2. Create the shared `edge` network (once per box)

```bash
ssh nila-prod 'docker network create edge || true'
```

> The edge-ops Caddy and the Nila app both attach to this. It already exists if
> some other app set it up — `|| true` makes this idempotent.

### 3. Seed Nila's server directory + secrets

```bash
ssh nila-prod 'mkdir -p /home/deploy/nila'

# Copy the env template, then fill in real secrets on the server
scp hetzner/.env.example nila-prod:/home/deploy/nila/.env
ssh nila-prod 'nano /home/deploy/nila/.env'
```

Generate the secrets locally and paste them in:

```bash
mix phx.gen.secret                 # → SECRET_KEY_BASE
openssl rand -base64 32            # → POSTGRES_PASSWORD (also put it in DATABASE_URL)
openssl rand -base64 48            # → WHATSAPP_COMPLETENESS_SECRET (minimum 32 bytes)
```

Make sure `DATABASE_URL` uses the **same** password and points at the
`nila-postgres` service host, e.g.
`ecto://nila:<password>@nila-postgres/nila_prod`.

The server must also be logged in to GHCR to pull the private image (already
done for the edge-ops stack on this box; re-run if needed):

```bash
echo <GHCR_PAT> | ssh nila-prod 'docker login ghcr.io -u <github-user> --password-stdin'
```

### 4. Roll out the shared-Caddy changes (edge-ops repo)

The `edge` network attachment and the `nila.tax` vhost (plus the `nilahq.com` →
`nila.tax` redirect) live in the **edge-ops** repo (`caddy/Caddyfile`). The
`nila.tax` origin certificate and key must be present as
`certs/nila-tax-origin.pem` and `certs/nila-tax-origin-key.pem`. Deploy them once:

```bash
# from the edge-ops repo
./scripts/deploy.sh
```

This only works **after** step 2 — the external `edge` network must exist or
compose errors out.

### 5. First Nila deploy

Push `main`; the push automatically runs `.github/workflows/deploy.yml`:

```bash
# from the nila repo

git push origin main
```

The workflow builds the image, pushes it to GHCR, syncs the two ops files, runs
migrations, and starts the stack. DNS for `nila.tax` must point at Cloudflare →
the box IP, with the origin cert active (proxied / orange-cloud).

Verify:

```bash
curl -s https://nila.tax/health        # {"status":"healthy","db":"ok","oban":"ok"}
```

### 6. Allow browser uploads to the R2 bucket (CORS)

Intake presigns a `PUT` and the browser sends the file **straight to R2** — the
bytes never reach this box. R2 rejects a cross-origin `PUT` from a browser
unless the bucket says otherwise, so without this the drop zone fails on every
upload with a CORS error, while `curl` against the same presigned URL succeeds.

Cloudflare dashboard → R2 → `nila-documents` → Settings → CORS policy:

```json
[
  {
    "AllowedOrigins": ["https://nila.tax"],
    "AllowedMethods": ["PUT"],
    "AllowedHeaders": ["content-type"],
    "ExposeHeaders": [],
    "MaxAgeSeconds": 3600
  }
]
```

Only `https://nila.tax` belongs in `AllowedOrigins`. Dev and test never touch
R2 — they PUT to the app's own `/uploads/local`, which stands in for the bucket.

Verify from the browser console on `https://nila.tax`, or just drop a bill into
`/gst/upload` and watch the network tab for a `200` on the R2 `PUT`.

---

## Day-to-day

### Deploy

Every push to `main` deploys automatically. `./scripts/deploy.sh` is the manual
redeploy path: it dispatches the workflow for the current remote `main` and
watches the run. The local `HEAD` must already be pushed, and the script requires
an authenticated `gh` CLI.

```bash
git push origin main                    # normal deploy
./scripts/deploy.sh                     # manual redeploy of an already-pushed HEAD
```

### Status / logs

```bash
ssh nila-prod 'cd /home/deploy/nila && docker compose ps'
ssh nila-prod 'cd /home/deploy/nila && docker compose logs nila --tail=100'
ssh nila-prod 'cd /home/deploy/nila && docker compose logs -f nila'
```

### Run migrations manually

```bash
ssh nila-prod 'cd /home/deploy/nila && docker compose run --rm nila /app/bin/migrate'
```

### IEx console on the running node

```bash
./scripts/prod-console
```

Exit with `Ctrl-G q Enter` (not `Ctrl-C` — that interrupts the live node).

The script uses the `nila-prod` alias configured at the top of this document.
Without the alias, the explicit raw form must name the identity file:

```bash
ssh -i ~/.ssh/hetzner_deploy -t deploy@46.224.237.179 \
  'cd /home/deploy/nila && docker compose exec nila /app/bin/nila remote'
```

### Update env vars

Edit the server file, then recreate the app container:

```bash
ssh -t nila-prod 'nano /home/deploy/nila/.env'
ssh nila-prod 'cd /home/deploy/nila && docker compose up -d nila'
```

That command applies application runtime variables only. Changing `POSTGRES_*`
does not alter credentials inside an existing database volume; rotate the
Postgres role explicitly rather than recreating the container and expecting the
environment to rewrite it.

### Database backup (you own this — it's a self-hosted container)

```bash
ssh nila-prod \
  'cd /home/deploy/nila && docker compose exec -T nila-postgres pg_dump -U nila nila_prod' \
  | gzip > "nila_$(date +%F).sql.gz"
```

> This stack configures no automated backup job. Add a host timer or backup
> service that runs `pg_dump` and ships it off-box; until then, backups are
> manual.

---

## Secrets

Application runtime secrets are sourced from `/home/deploy/nila/.env` on the
box. The deploy pipeline never ships that file; its separate SSH credentials
live in GitHub Actions secrets. `docker-compose.yml` loads `.env` via `env_file:`
and `config/runtime.exs` reads each value at boot. Editing the repo or your local
`.env` does not change prod; edit the server file and recreate the app container
as shown above.

### Handling rules

- Keep a copy of the prod `.env` in a password manager (1Password / Bitwarden).
  Without that recovery copy, losing the box means regenerating
  `SECRET_KEY_BASE` (which logs everyone out) and recovering every API and DB
  credential by hand.
- Lock the file down: `chmod 600 /home/deploy/nila/.env`, owned by `deploy`.
- Never commit the real `.env`. Only `hetzner/.env.example` (placeholders) is
  tracked.

### Required in prod

The app refuses to boot, or compose errors, without these:

| Var | Purpose |
| --- | --- |
| `SECRET_KEY_BASE` | Signs and encrypts cookies and sessions. Generate with `mix phx.gen.secret`. |
| `DATABASE_URL` | Ecto connection string. Must use the same password as `POSTGRES_PASSWORD` and point at host `nila-postgres`. |
| `ASSISTANT_API_KEY` | API key for the OpenAI-compatible assistant. `runtime.exs` raises in prod if missing. |
| `GST_TEXT_API_KEY` | API key for the direct-vision extraction provider. |
| `GST_TEXT_BASE_URL` / `GST_TEXT_MODEL` | Vision-capable OpenAI API root and model; production uses Vercel AI Gateway with `alibaba/qwen3.7-flash`. |
| `R2_ENDPOINT` / `R2_BUCKET` | Private Cloudflare R2 account endpoint and bucket name. |
| `R2_ACCESS_KEY_ID` / `R2_SECRET_ACCESS_KEY` | Bucket-scoped R2 Object Read & Write credentials. |
| `POSTGRES_USER` / `POSTGRES_PASSWORD` / `POSTGRES_DB` | Postgres container credentials, interpolated by Compose. |
| `WHATSAPP_APP_SECRET` / `WHATSAPP_VERIFY_TOKEN` | Meta webhook signature secret and verification token. Both are boot-required in prod. |
| `WHATSAPP_CHASE_TEMPLATE` | Pre-approved Cloud API template for document-chase messages. Boot-required; production currently uses `nila_document_chase`. |
| `WHATSAPP_COMPLETENESS_TEMPLATE` | Pre-approved Cloud API template for sales-completeness questions. Boot-required; production currently uses `nila_sales_completeness`. |
| `WHATSAPP_COMPLETENESS_SECRET` | Signs period-specific Yes/No quick replies. Boot-required and must be at least 32 bytes. |

`PHX_SERVER`, `PORT`, and `PHX_HOST` are set in `docker-compose.yml`
(`environment:`), so they do not belong in `.env`.

### Optional

Unless noted, absence disables the feature or leaves the compiled default:

| Var | Default / effect when unset |
| --- | --- |
| `ASSISTANT_BASE_URL` | Defaults to `https://api.stepfun.ai/v1`. Set to switch provider (e.g. NVIDIA `https://integrate.api.nvidia.com/v1`). |
| `ASSISTANT_MODEL` | Defaults to `step-3.7-flash`. |
| `ASSISTANT_RECEIVE_TIMEOUT` | Upstream read timeout in ms (default `60000`). |
| `ASSISTANT_EXTRA_HEADERS` | JSON object merged into every assistant request for gateway routing. Invalid JSON fails boot. |
| `GST_TEXT_PROVIDER` | Audit identity for the OpenAI-compatible vision provider; production uses `vercel-ai-gateway`. |
| `GST_TEXT_RESPONSE_FORMAT` | Use `json_schema_local` for Vercel so Nila validates every response locally. |
| `GST_TEXT_HTTP_PROTOCOL` | Provider transport; Vercel uses `http2`. |
| `GST_TEXT_PROVIDER_OPTIONS` | JSON sent as Vercel `providerOptions`; production disables Qwen thinking with `{"alibaba":{"enableThinking":false}}`. |
| `MISTRAL_API_KEY` / `MISTRAL_BASE_URL` | Optional legacy OCR extractor credentials and endpoint. |
| `RESEND_API_KEY` | Switches `Nila.Mailer` to Resend and configures inbound Resend API access. **Unset means invite emails are silently dropped in prod**, so this is effectively required to onboard teammates. |
| `MAIL_FROM` / `MAIL_FROM_NAME` | Sender for outgoing mail (default `Nila <onboarding@resend.dev>`). `nila.tax` is verified; production should use `MAIL_FROM=noreply@nila.tax`. Read only when `RESEND_API_KEY` is set. |
| `INBOUND_EMAIL_DOMAIN` / `INBOUND_EMAIL_SECRET` | Overrides the compiled inbound-address domain and signing secret. Runtime requires the secret when the domain override is set. If both are omitted, the current compiled development defaults remain active—do not mistake omission for disabling inbound. |
| `RESEND_WEBHOOK_SECRET` | Verifies inbound Resend webhook signatures. Without it the webhook is unconfigured. |
| `INTEGRATION_CREDENTIAL_KEY` | Encrypts stored integration credentials. Falls back to `SECRET_KEY_BASE`; set it explicitly so rotating session secrets cannot lock saved connectors. |
| `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET` / `GMAIL_REDIRECT_URI` | Gmail integration. Inactive when unset. |
| `MICROSOFT_CLIENT_ID` / `MICROSOFT_CLIENT_SECRET` / `MICROSOFT_REDIRECT_URI` | Microsoft integration. Inactive when unset. |
| `WHATSAPP_APP_ID` / `WHATSAPP_EMBEDDED_SIGNUP_CONFIG_ID` | Enables Embedded Signup. If either is supplied, both plus the required app secret must be present or boot fails. |
| `WHATSAPP_EMBEDDED_SIGNUP_ALLOWED_BUSINESS_ID` | Optional. Pins onboarding to one Meta business for controlled testing. Leave unset in production and App Review so any customer business can authorise. |
| `WHATSAPP_GRAPH_URL` | Overrides Meta's Graph base URL. Must be HTTPS and end in `/vN.N`; default is `https://graph.facebook.com/v26.0`. |
| `R2_EVAL_ACCESS_KEY_ID` / `R2_EVAL_SECRET_ACCESS_KEY` | Optional credentials for the eval corpus; it reuses `R2_ENDPOINT`. |
| `POOL_SIZE` | DB pool size (default `10`). |
| `ECTO_IPV6` | Set `true`/`1` for an IPv6 DB socket. |
| `DNS_CLUSTER_QUERY` | libcluster DNS query. Unset means no clustering, which is correct for one app node. |

---

## Notes / gotchas

- **`force_ssl` is on** (`config/prod.exs`) with `/health` and `localhost`/
  `127.0.0.1` excluded, and `rewrite_on: [:x_forwarded_proto]`. Caddy must keep
  setting `X-Forwarded-Proto: https`; otherwise browser POST routes such as login
  and contact callback can be redirected before Phoenix handles them.
- **`check_origin`** is `["https://#{PHX_HOST}"]` → `["https://nila.tax"]` (runtime.exs). If you add another
  hostname that should serve the app directly (not redirect), add it there or
  the LiveView socket will refuse the connection.
- **Caddy reaches `nila` by network alias**, set in
  `hetzner/docker-compose.yml` (`networks.edge.aliases: [nila]`). Renaming that
  alias means updating the edge-ops Caddyfile too.
- Postgres is **not** exposed outside the `internal` network — connect via
  `docker compose exec nila-postgres psql ...`.
