import { fileURLToPath, URL } from "node:url";
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";

export default defineConfig(({ command }) => ({
  base: command === "build" ? "/frontend/" : "/",
  build: { outDir: "../priv/static/frontend", emptyOutDir: true },
  plugins: [react(), tailwindcss()],
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
