# Phoenix web code

- Product screens and auth pages use React in `frontend/`. Do not add LiveViews.
- Controllers authenticate and authorize requests, then call contexts in `lib/nila/`.
- Keep API presentation helpers in `lib/nila_web/gst/`, separate from UI templates.
- Update OpenAPI response contracts and generated TypeScript when APIs change.
- Marketing, contact and legal pages use build-time React HTML from `frontend/src/public/`.
  `PublicPage` adds escaped form values and CSRF tokens; Phoenix validates callback requests.
- Error pages use static HEEx and `assets/css/app.css`, independent of React.
- Use normal `href` links and HTTP forms on static pages, not LiveView navigation.
- `phoenix_live_view` remains for Phoenix.Component/HEEx tooling; there is no
  product LiveView runtime, socket or route.
- Scope blocks already alias routes. Do not repeat the scope's module prefix.
- Use Phoenix components, not the removed Phoenix.View API.
