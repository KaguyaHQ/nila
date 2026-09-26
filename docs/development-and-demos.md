# Development and demonstrations

Local data is disposable. Use `mix nila.dev.reset` with the local Phoenix server
stopped to recreate `nila_dev`, run migrations, and create two workspace logins.
This command refuses production, remote hosts, and other database names.

Open `/users/log_in`: **Firm workspace** opens the demo firm; **Business workspace**
opens Example Business. Quick login exists only in development, selects active
users with the appropriate access in a demo firm, and excludes other accounts.
These are different product roles, not separate development/demo account types.

The baseline contains a firm, owner, business user, client and business profile.
It creates no transactions. Run `mix run priv/repo/business_seeds.exs` to add an
optional example customer, saved item and draft invoice. Re-running seeds on this
baseline is safe. Existing ad-hoc databases should use the rebuild command once
to adopt it; seed scripts are not account migration tools.

## Reset a presentation

In a designated demo firm, an owner opens **Settings → Firm → Demo data → Reset
demo**. Confirmation names the firm. Reset deletes every client and their work
across all months, including sales, purchases, business documents, business access
and retained integration state. Firm details, users, memberships and sign-in
sessions survive. It does not recreate a particular client or packet. Create any
client for the next presentation.

Reset refuses while a scoped background job is executing; queued and retryable
jobs are removed with the records. It can be repeated on an empty firm. Another
firm's data is outside the reset. There are no reset backups. Uploaded files and
generated artifacts in storage are not physically purged by this database reset;
their application records and access through the workspace are removed.

Locally, clearing clients also removes the business user's workspace access.
Run `mix run priv/repo/seeds.exs` to restore the local example business and its
shortcut. This does not change the hosted demo's empty starting point.

## Designate a hosted demo firm

Deploy the schema and code before designation. Through `scripts/prod-console`,
inspect the firms and then explicitly designate the intended firm:

```elixir
Nila.Orgs.list_orgs()
Nila.Demo.designate(firm_id)
```

The `is_demo` flag is operator-managed and cannot be set through firm settings or
ordinary provisioning. The server checks the current flag, active user and owner
membership for every reset. Names, emails, client GSTINs and months do not grant
reset access. Designation alone does not delete anything.

The hosted app can serve as the presentation environment while there are no
customers. This does not enable development quick login in a production release.
