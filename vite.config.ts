import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// https://vite.dev/config/
export default defineConfig({
  plugins: [react()],
  clearScreen: false, // don't obscure rust errors
  server: {
    port: 1420, // tauri expects a fixed port
    strictPort: true,
    watch: { ignored: ["**/src-tauri/**"] },
  },
});
