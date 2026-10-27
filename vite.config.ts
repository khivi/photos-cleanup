import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Dev proxy to the FastAPI server: `uv run python sidecar/server.py --no-browser`
const api = "http://127.0.0.1:8765";
const routes = ["/health", "/stats", "/photos", "/thumb", "/cleanup", "/commit"];

// https://vite.dev/config/
export default defineConfig({
  plugins: [react()],
  server: {
    proxy: Object.fromEntries(routes.map((r) => [r, api])),
  },
});
