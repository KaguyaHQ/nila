import { fileURLToPath, URL } from "node:url";
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";

export default defineConfig(({ command }) => ({
  base: command === "build" ? "/frontend/" : "/",
  build: {
    outDir: "../priv/static/frontend",
    emptyOutDir: true,
    manifest: true,
    rollupOptions: {
      input: {
        app: fileURLToPath(new URL("./index.html", import.meta.url)),
        story: fileURLToPath(new URL("./src/public/animate.ts", import.meta.url)),
      },
    },
  },
  plugins: [
    react(),
    tailwindcss(),
    {
      name: "nila-public-preview",
      configureServer(server) {
        server.middlewares.use("/__public", async (req, res, next) => {
          const page = req.url?.slice(1);
          if (
            !page ||
            ![
              "home",
              "india",
              "business",
              "contact",
              "india_contact",
              "privacy",
              "terms",
              "data_deletion",
            ].includes(page)
          )
            return next();
          try {
            const { renderPublicPage } = await server.ssrLoadModule("/src/public/render.tsx");
            res.setHeader("Content-Type", "application/json");
            res.end(JSON.stringify(renderPublicPage(page)));
          } catch (error) {
            next(error);
          }
        });
      },
    },
  ],
  resolve: { alias: { "@": fileURLToPath(new URL("./src", import.meta.url)) } },
  server: {
    host: "127.0.0.1",
    port: 5173,
    strictPort: true,
    origin: process.env.NILA_VITE_ORIGIN,
    cors: { origin: /^http:\/\/(localhost|127\.0\.0\.1):4000$/ },
    fs: {
      allow: [
        fileURLToPath(new URL(".", import.meta.url)),
        fileURLToPath(new URL("../priv/static/fonts", import.meta.url)),
      ],
    },
  },
}));
