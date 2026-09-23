# Remaining LiveView migration

Auth now uses React/shadcn at the existing `/users/*` URLs. Native forms post to
Phoenix; sessions, remember-me, invitations, password reset and verification stay
in Accounts/UserAuth. Signup remains invite-only and redirects to Contact.
The email-change token endpoint is a controller returning to React settings.

## Duplicate screens removed

- Clients list/new/edit, notices list/detail, settings profile/security/workspace/users.
- Purchases overview/register/invoice review; GSTR-2B connection/fetching.

Retired URLs are removed. There is no bookmark compatibility layer.
Retained screens link directly to React.
API, export, download and evidence controllers remain.

## Shared sales code still to separate

- Sales summary/register/checks and month review still live in `MonthLive`.
  The old GSTR-3B route, screen and UI sign-off handlers are now removed.
  Backend calculations and sign-off rules remain unchanged.
- The batch viewer and invoice viewer include Tally/accounting work. Audit those
  entry paths with the deferred Tally scope before removing their modules.

## Still needed or explicitly deferred

- Excel import screens and purchase upload history: preserve existing React handoffs.
- Generic `/gst/upload` intake: inspect its remaining callers and supported formats.
- GSTR-3B UI: retired with no replacement. The former URL is no longer routed.
- Banking and Tally connector/pairing: shelved, removal is a separate decision.
- Marketing/contact/legal pages: server-rendered controllers, not LiveView.
- Development LiveDashboard/design reference: not product migration blockers.

## Cleanup order

1. Remove the remaining old sales routes and their `MonthLive` UI.
2. Resolve the remaining batch/invoice viewer dependency on Tally work.
3. Decide and migrate remaining import flows.
4. Audit banking/Tally jobs, data and shared dependencies before removing shelved code.
5. Remove LiveView dependencies/assets only when no retained routes use them.

Historical pre-React code is archived privately in `KaguyaHQ/nila-pre-react-archive`
at `3328ee29e4f09c667e39b42132c65bbd6c3f3c1b`. This is code history, not a data backup.
