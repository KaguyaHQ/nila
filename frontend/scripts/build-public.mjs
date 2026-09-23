import { mkdir, writeFile } from "node:fs/promises";
import { createServer } from "vite";

// Build-time React rendering. No Node server or application JS is needed in production.
const server = await createServer({
  cacheDir: "node_modules/.cache/public-render",
  server: { middlewareMode: true },
  appType: "custom",
});
try {
  const { renderPublicPages } = await server.ssrLoadModule("/src/public/render.tsx");
  await mkdir("../priv/static/frontend", { recursive: true });
  await writeFile("../priv/static/frontend/public-pages.json", JSON.stringify(renderPublicPages()));
} finally {
  await server.close();
}
