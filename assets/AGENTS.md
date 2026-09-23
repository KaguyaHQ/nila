# LiveView assets

- Preserve existing LiveView components and semantic tokens unless migration is requested.
- Preserve Tailwind v4 `@import`/`@source` declarations in `css/app.css`; never use `@apply`.
- Use the existing `app.js` and `app.css` builds. Import dependencies through the build, not external script or stylesheet tags.
- React has its own Vite build in `frontend/`; do not port LiveView DOM hooks into React controls.
- Run `mix nila.style_guard` for affected LiveView styles.
