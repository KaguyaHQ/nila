# Static error-page assets

- These assets serve standalone error pages. Marketing/contact/legal pages are built in `frontend/`.
- Preserve their existing components and semantic tokens unless redesign is requested.
- Preserve Tailwind v4 import/source declarations; never use `@apply`.
- Import dependencies through the existing app.js/app.css build.
- Do not reintroduce LiveView hooks or socket boot code.
- React and its PDF renderer are in `frontend/` with their own Vite build.
- Run `mix nila.style_guard` for affected public-page styles.
