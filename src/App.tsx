import { useEffect, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import "./App.css";

type Stats = { count: number; size_gb: number };

function App() {
  const [stats, setStats] = useState<Stats | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      const port = await invoke<number>("sidecar_port");
      // Sidecar may still be booting / loading the library; retry ~2 min.
      for (let i = 0; i < 120 && !cancelled; i++) {
        try {
          const r = await fetch(`http://127.0.0.1:${port}/stats`);
          if (r.ok) {
            if (!cancelled) setStats(await r.json());
            return;
          }
        } catch {
          /* not up yet */
        }
        await new Promise((res) => setTimeout(res, 1000));
      }
      if (!cancelled) setError("Sidecar did not respond");
    })();
    return () => {
      cancelled = true;
    };
  }, []);

  return (
    <main className="container">
      <h1>Photo Cleanup</h1>
      {error && <p style={{ color: "crimson" }}>{error}</p>}
      {!stats && !error && <p>Loading library…</p>}
      {stats && (
        <p style={{ fontSize: "1.4rem" }}>
          <strong>{stats.count.toLocaleString()}</strong> photos ·{" "}
          <strong>{stats.size_gb}</strong> GB
        </p>
      )}
    </main>
  );
}

export default App;
