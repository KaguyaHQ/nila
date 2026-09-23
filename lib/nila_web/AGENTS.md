# Phoenix web code

- Product screens and auth pages use React in `frontend/`. Do not add LiveViews.
- Controllers authenticate and authorize requests, then call contexts in `lib/nila/`.
- Keep API presentation helpers in `lib/nila_web/gst/`, separate from UI templates.
- Update OpenAPI response contracts and generated TypeScript when APIs change.
- Marketing, contact and legal pages use build-time React HTML from `frontend/src/public/`.
  `PublicPage` adds escaped form values and CSRF tokens; Phoenix validates callback requests.
- Error pages read standalone HTML built from React in `frontend/src/public/`. They need no browser JavaScript, database or running frontend server.
- Use normal `href` links and HTTP forms on static pages, not LiveView navigation.
- LiveView and HEEx UI are removed. Do not reintroduce them.
- Scope blocks already alias routes. Do not repeat the scope's module prefix.
- Keep HTML rendering in the React build; controllers serve the generated documents.
