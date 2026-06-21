# Nila — Hetzner Deployment

Nila runs on the **same Hetzner box as kaguya** (`46.224.237.179`, Nuremberg),
as its own compose project at `/home/deploy/nila`. Kaguya's Caddy is the shared
ingress (owns ports 80/443) and reverse-proxies `nilahq.com` to Nila's container
over a shared Docker network named `edge`.

```
Browser → Cloudflare (TLS + cache) → Caddy (kaguya stack) ──edge──▶ nila:8080 (Phoenix LiveView)
                                                                       │ internal
                                                                       ▼
                                                                 nila-postgres:5432
```

- **Domain**: `nilahq.com` (Cloudflare origin cert in `kaguya-api/hetzner/certs/nila-origin*.pem` — regenerate for `nilahq.com`, see notes below)
- **Image**: `ghcr.io/kaguyahq/nila` (built by `.github/workflows/deploy.yml`)
- **DB**: dedicated `postgres:16` container, private `internal` network, volume `nila_pgdata`
- **Server files**: `/home/deploy/nila/` (`docker-compose.yml`, `deploy.sh`, `.env`)

---

## One-time bootstrap

Steps 1–4 are manual the first time; after that, deploys are just
`./scripts/deploy.sh`.

### 1. GitHub repo secrets (KaguyaHQ/nila)

Add the same secrets the kaguya repo uses (Settings → Secrets → Actions):

- `HETZNER_HOST` — `46.224.237.179`
- `HETZNER_SSH_KEY` — the `deploy` user's private SSH key

### 2. Create the shared `edge` network (once per box)

```bash
ssh deploy@46.224.237.179 'docker network create edge || true'
```

> The kaguya Caddy and the Nila app both attach to this. It already exists if
> some other app set it up — `|| true` makes this idempotent.

### 3. Seed Nila's server directory + secrets

```bash
ssh deploy@46.224.237.179 'mkdir -p /home/deploy/nila'

# Copy the env template, then fill in real secrets on the server
scp hetzner/.env.example "deploy@46.224.237.179:/home/deploy/nila/.env"
ssh deploy@46.224.237.179 'nano /home/deploy/nila/.env'
```

Generate the secrets locally and paste them in:

```bash
mix phx.gen.secret                 # → SECRET_KEY_BASE
openssl rand -base64 32            # → POSTGRES_PASSWORD (also put it in DATABASE_URL)
```

Make sure `DATABASE_URL` uses the **same** password and points at the
`nila-postgres` service host, e.g.
`ecto://nila:<password>@nila-postgres/nila_prod`.

The server must also be logged in to GHCR to pull the private image (already
done for kaguya on this box; re-run if needed):

```bash
echo <GHCR_PAT> | ssh deploy@46.224.237.179 'docker login ghcr.io -u <github-user> --password-stdin'
```

### 4. Roll out the shared-Caddy changes (kaguya repo)

The `edge` network attachment and the `nilahq.com` block live in the **kaguya**
repo (`hetzner/docker-compose.yml` + `hetzner/Caddyfile`). Deploy them once:

```bash
# from the kaguya-api repo
./scripts/deploy.sh
```

This only works **after** step 2 — the external `edge` network must exist or
compose errors out.

### 5. First Nila deploy

```bash
# from the nila repo
./scripts/deploy.sh
```

This builds the image, pushes to GHCR, syncs ops files, runs migrations, and
starts the stack. DNS for `nilahq.com` must point at Cloudflare → the box IP, with
the origin cert active (proxied / orange-cloud).

Verify:

```bash
curl -s https://nilahq.com/health        # {"status":"healthy","db":"ok","oban":"ok"}
```

---

## Day-to-day

### Deploy

```bash
./scripts/deploy.sh                     # triggers GitHub Actions, watches the run
```

### Status / logs

```bash
ssh deploy@46.224.237.179 'cd /home/deploy/nila && docker compose ps'
ssh deploy@46.224.237.179 'cd /home/deploy/nila && docker compose logs nila --tail=100'
ssh deploy@46.224.237.179 'cd /home/deploy/nila && docker compose logs -f nila'
```

### Run migrations manually

```bash
ssh deploy@46.224.237.179 'cd /home/deploy/nila && docker compose run --rm nila /app/bin/migrate'
```

### IEx console on the running node

```bash
./scripts/prod-console
```

Exit with `Ctrl-G q Enter` (not `Ctrl-C` — that interrupts the live node).

The script needs this block in `~/.ssh/config`:

```sshconfig
Host kaguya-prod nila-prod
    HostName 46.224.237.179
    User deploy
    IdentityFile ~/.ssh/hetzner_deploy
    IdentitiesOnly yes
```

Without the wrapper, the raw form is:

```bash
ssh -t deploy@46.224.237.179 'cd /home/deploy/nila && docker compose exec nila /app/bin/nila remote'
```

### Update env vars

Edit `/home/deploy/nila/.env`, then:

```bash
ssh deploy@46.224.237.179 'cd /home/deploy/nila && docker compose up -d nila'
```

### Database backup (you own this — it's a self-hosted container)

```bash
ssh deploy@46.224.237.179 \
  'cd /home/deploy/nila && docker compose exec -T nila-postgres pg_dump -U nila nila_prod' \
  | gzip > "nila_$(date +%F).sql.gz"
```

> TODO: add a cron job on the box (or a small Oban worker) that runs `pg_dump`
> nightly and ships the dump off-box (e.g. to R2/S3). Until then, backups are
> manual.

---

## Secrets

Secrets live in exactly one place: `/home/deploy/nila/.env` on the box. The
deploy pipeline never ships them. `docker-compose.yml` loads the file via
`env_file:` and `config/runtime.exs` reads each value at boot. Editing the repo
or your local `.env` does not change prod; you edit the file on the server (see
"Update env vars" above), then `docker compose up -d nila`.

### Handling rules

- Keep a copy of the prod `.env` in a password manager (1Password / Bitwarden).
  The box is the only live copy, so if it dies you would otherwise have to
  regenerate `SECRET_KEY_BASE` (logs everyone out) and recover every API and DB
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
| `POSTGRES_USER` / `POSTGRES_PASSWORD` / `POSTGRES_DB` | Postgres container credentials, interpolated by compose. |

`PHX_SERVER`, `PORT`, and `PHX_HOST` are set in `docker-compose.yml`
(`environment:`), so they do not belong in `.env`.

### Optional

Absent means the feature is off or a default applies:

| Var | Default / effect when unset |
| --- | --- |
| `ASSISTANT_BASE_URL` | Defaults to `https://api.stepfun.ai/v1`. Set to switch provider (e.g. NVIDIA `https://integrate.api.nvidia.com/v1`). |
| `ASSISTANT_MODEL` | Defaults to `step-3.7-flash`. |
| `ASSISTANT_RECEIVE_TIMEOUT` | Upstream read timeout in ms (default 60000). |
| `ASSISTANT_EXTRA_HEADERS` | JSON object merged into every assistant request (LLM-gateway routing). |
| `RESEND_API_KEY` | When set, `Nila.Mailer` switches from the dev mailbox to Resend. **Unset means invite emails are silently dropped in prod** (the mailer is inert), so this is effectively required to onboard teammates. |
| `MAIL_FROM` / `MAIL_FROM_NAME` | Sender for outgoing mail (default `Nila <onboarding@resend.dev>`). The from-address domain must be verified in Resend; `onboarding@resend.dev` only delivers to your own Resend account email. Set `MAIL_FROM=noreply@nilahq.com` after verifying the domain. Only read when `RESEND_API_KEY` is set. |
| `LLAMA_CLOUD_API_KEY` | When set, PO extraction switches from the Stub to real LlamaExtract. Unset means no real extraction. |
| `LLAMA_PROJECT_ID` / `LLAMA_BASE_URL` / `LLAMA_TIER` / `LLAMA_VERSION` | Only read when `LLAMA_CLOUD_API_KEY` is set. Pin `LLAMA_VERSION` in prod. |
| `INTEGRATION_CREDENTIAL_KEY` | Encrypts stored integration credentials. Falls back to `SECRET_KEY_BASE` if unset; set it explicitly so rotating `SECRET_KEY_BASE` does not lock you out of saved credentials. |
| `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET` / `GMAIL_REDIRECT_URI` | Gmail integration. Inactive in prod when unset. |
| `WHATSAPP_APP_SECRET` / `WHATSAPP_VERIFY_TOKEN` | WhatsApp webhook. Inactive in prod when unset. |
| `POOL_SIZE` | DB pool size (default 10). |
| `ECTO_IPV6` | Set `true`/`1` for an IPv6 DB socket. |
| `DNS_CLUSTER_QUERY` | libcluster DNS query. Unset means no clustering (fine for one box). |

---

## Notes / gotchas

- **`force_ssl` is on** (`config/prod.exs`) with `/health` and `localhost`/
  `127.0.0.1` excluded, and `rewrite_on: [:x_forwarded_proto]`. Caddy sets
  `X-Forwarded-Proto: https`, so POSTs are never 301'd (the bug that bit kaguya
  came from an SSR POST path Nila doesn't have — but keep an eye on it if you
  add controller-based form POSTs).
- **`check_origin`** is `["https://#{PHX_HOST}"]` → `["https://nilahq.com"]` (runtime.exs). If you add another
  hostname that should serve the app directly (not redirect), add it there or
  the LiveView socket will refuse the connection.
- **Caddy reaches `nila` by network alias**, set in
  `hetzner/docker-compose.yml` (`networks.edge.aliases: [nila]`). Renaming that
  alias means updating the kaguya Caddyfile too.
- Postgres is **not** exposed outside the `internal` network — connect via
  `docker compose exec nila-postgres psql ...`.
