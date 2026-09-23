# Phoenix web code

- Product screens and auth pages use React in `frontend/`. Do not add LiveViews.
- Controllers authenticate and authorize requests, then call contexts in `lib/nila/`.
- Keep API presentation helpers in `lib/nila_web/gst/`, separate from UI templates.
- Update OpenAPI response contracts and generated TypeScript when APIs change.
- Public marketing, contact, legal and error pages use static HEEx. Their components
  and semantic tokens are in `components/` and `assets/css/app.css`.
- Use normal `href` links and HTTP forms on static pages, not LiveView navigation.
- `phoenix_live_view` remains for Phoenix.Component/HEEx tooling; there is no
  product LiveView runtime, socket or route.
- Scope blocks already alias routes. Do not repeat the scope's module prefix.
- Use Phoenix components, not the removed Phoenix.View API.
