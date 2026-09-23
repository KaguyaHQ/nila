# Remaining LiveView migration

Auth now uses React/shadcn at the existing `/users/*` URLs. Native forms post to
Phoenix; sessions, remember-me, invitations, password reset and verification stay
in Accounts/UserAuth. Signup remains invite-only and redirects to Contact.
The email-change token endpoint is a controller returning to React settings.

## Replaced, but still routed to old screens

- Clients list/new/edit, notices list/detail, settings profile/security/workspace/users.
- Sales summary/register/checks/invoice review and PDF upload/history.
- Purchases overview/register/invoice review; GSTR-2B connection/fetching.

Before deleting these, update remaining legacy links and decide redirects for
existing URLs. Keep API, export, download and evidence controllers used by React.
`MonthLive` also owns GSTR-3B: do not delete the module with its sales actions.

## Still needed or explicitly deferred

- Excel import screens and purchase upload history: preserve existing React handoffs.
- Generic `/gst/upload` intake: inspect its remaining callers and supported formats.
- `/gst/:client_id/:period/gstr3b`: no React replacement; previously deferred.
- Banking and Tally connector/pairing: shelved, removal is a separate decision.
- Marketing/contact/legal pages: server-rendered controllers, not LiveView.
- Development LiveDashboard/design reference: not product migration blockers.

## Cleanup order

1. Replace remaining links into duplicate screens, then remove their routes/modules/tests.
2. Separate GSTR-3B from replaced `MonthLive` actions.
3. Decide and migrate remaining import flows.
4. Audit banking/Tally jobs, data and shared dependencies before removing shelved code.
5. Remove LiveView dependencies/assets only when no retained routes use them.

Historical pre-React code is archived privately in `KaguyaHQ/nila-pre-react-archive`
at `3328ee29e4f09c667e39b42132c65bbd6c3f3c1b`. This is code history, not a data backup.
