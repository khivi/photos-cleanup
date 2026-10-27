import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Dev proxy to the FastAPI server: `uv run photos-cleanup --dev`
const api = "http://127.0.0.1:8765";
const routes = ["/health", "/stats", "/photos", "/thumb", "/cleanup", "/commit", "/counts", "/verdict-stats"];

// https://vite.dev/config/
export default defineConfig({
  plugins: [react()],
  build: { outDir: "photos_cleanup/ui", emptyOutDir: true },
  server: {
    proxy: Object.fromEntries(routes.map((r) => [r, api])),
  },
});
