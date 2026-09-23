import { mkdir, readFile, writeFile } from "node:fs/promises";
import { createServer } from "vite";

// Build-time React rendering. No Node server or application JS is needed in production.
const server = await createServer({
  cacheDir: "node_modules/.cache/public-render",
  server: { middlewareMode: true },
  optimizeDeps: { noDiscovery: true, entries: [] },
  appType: "custom",
});
try {
  const { renderPublicPages, renderErrorPage } = await server.ssrLoadModule("/src/public/render.tsx");
  await mkdir("../priv/static/frontend", { recursive: true });
  await writeFile("../priv/static/frontend/public-pages.json", JSON.stringify(renderPublicPages()));
  const index = await readFile("../priv/static/frontend/index.html", "utf8");
  const styles = (index.match(/<link[^>]+rel="stylesheet"[^>]*>/g) ?? []).join("");
  for (const status of [404, 500]) {
    const title = status === 404 ? "Page not found" : "Server error";
    await writeFile(
      `../priv/static/frontend/error-${status}.html`,
      `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><meta name="robots" content="noindex"><title>${title} · Nila</title><link rel="icon" href="/favicon.ico">${styles}</head><body>${renderErrorPage(status)}</body></html>`,
    );
  }
} finally {
  await server.close();
}
