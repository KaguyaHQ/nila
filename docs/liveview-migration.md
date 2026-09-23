# Frontend ownership

React in `frontend/` owns the product UI and authentication pages. Phoenix owns
sessions, permissions, GST/accounting rules, persistence, jobs and HTTP APIs.
There are no LiveView pages, components, routes or `/live` socket.

Marketing, contact, legal and error pages use React source in `frontend/src/public/`,
rendered into HTML during the frontend build and served by Phoenix. Error documents
work without browser JavaScript or a running frontend server; missing build files
fall back to plain HTTP status text. LiveView, HEEx UI helpers and the old asset
pipeline have been removed. Vite is the only frontend build. Phoenix Channels
remain for the shelved Tally connector; they do not require LiveView.

## Retired UI

- All duplicate GST, clients, notices, settings and authentication LiveViews.
- Today/work queue, banking, batch viewer accounting mode and Tally pairing.
- GSTR-3B, without a replacement screen.
- Sales/purchase Excel import and purchase upload history. Existing imported
  records remain in the React registers. The Elixir import engines, templates,
  backend tests and stored data remain. Sales Excel UI will be designed using
  real client spreadsheets; purchase Excel UI is undecided.
- Email/WhatsApp connection setup. GST connection setup remains in React.
- Development LiveDashboard and the old design-system gallery.

Retired URLs are removed, without compatibility redirects. React navigation
memory is the sole client/month navigation contract. Sales API projections live
in `lib/nila_web/gst/`, independently of templates.

## Shelved integrations

Tally, banking and messaging domain code, data, jobs and existing connector
transport remain. New Tally pairings and email setup return HTTP 410 rather than
starting a flow whose UI has been removed. Already-started email callbacks and
approved Tally pairing exchanges remain supported. Existing integrations are
not disconnected, and schedules are not changed by this UI cleanup. Their
configuration must be managed through backend operations until a new UI is
approved. This pass does not inspect or modify production integration state.

Historical pre-React code is archived privately in `KaguyaHQ/nila-pre-react-archive`
at `3328ee29e4f09c667e39b42132c65bbd6c3f3c1b`. This is code history, not a data backup.
