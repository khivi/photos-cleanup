import { useEffect, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { FixedSizeGrid } from "react-window";
import "./App.css";

type Photo = { uuid: string; filename: string; is_video: boolean };
type View = "all" | "screenshots" | "low-quality";
type Decision = "keep" | "delete";

const CELL = 170; // px per thumbnail cell
const HEADER_H = 46; // toolbar height in px

/** Window size — available at first render, so no ref-mount timing trap. */
function useWindowSize() {
  const [size, setSize] = useState({
    width: window.innerWidth,
    height: window.innerHeight,
  });
  useEffect(() => {
    const onResize = () =>
      setSize({ width: window.innerWidth, height: window.innerHeight });
    window.addEventListener("resize", onResize);
    return () => window.removeEventListener("resize", onResize);
  }, []);
  return size;
}

function App() {
  const [port, setPort] = useState<number | null>(null);
  const [view, setView] = useState<View>("all");
  const [photos, setPhotos] = useState<Photo[]>([]);
  const [decisions, setDecisions] = useState<Record<string, Decision>>({});
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [committing, setCommitting] = useState(false);
  const [status, setStatus] = useState<string | null>(null);
  const { width, height } = useWindowSize();

  // Boot: get the sidecar port, wait for it, load the full library.
  useEffect(() => {
    let cancelled = false;
    (async () => {
      const p = await invoke<number>("sidecar_port");
      if (cancelled) return;
      setPort(p);
      for (let i = 0; i < 120 && !cancelled; i++) {
        try {
          const r = await fetch(`http://127.0.0.1:${p}/photos?limit=100000`);
          if (r.ok) {
            const data = await r.json();
            if (!cancelled) {
              setPhotos(data.photos);
              setLoading(false);
            }
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

  async function loadView(v: View) {
    if (port == null) return;
    setLoading(true);
    try {
      const path = v === "all" ? "/photos?limit=100000" : `/cleanup/${v}`;
      const r = await fetch(`http://127.0.0.1:${port}${path}`);
      const data = await r.json();
      setPhotos(data.photos);
      setView(v);
      // Cleanup candidates start flagged for delete; user toggles to keep.
      const next: Record<string, Decision> = {};
      if (v !== "all") for (const p of data.photos) next[p.uuid] = "delete";
      setDecisions(next);
    } finally {
      setLoading(false);
    }
  }

  function toggle(uuid: string) {
    setDecisions((prev) => ({
      ...prev,
      [uuid]: prev[uuid] === "delete" ? "keep" : "delete",
    }));
  }

  function setAll(d: Decision) {
    const next: Record<string, Decision> = {};
    for (const p of photos) next[p.uuid] = d;
    setDecisions(next);
  }

  async function commit() {
    if (port == null || view === "all") return;
    const uuids = Object.entries(decisions)
      .filter(([, d]) => d === "delete")
      .map(([u]) => u);
    if (uuids.length === 0) return;
    setCommitting(true);
    setStatus(null);
    // First commit triggers a macOS "control Photos" prompt; if it isn't
    // answered the request blocks. Time out so the UI never hangs forever.
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), 90_000);
    try {
      const r = await fetch(`http://127.0.0.1:${port}/commit`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ kind: view, uuids }),
        signal: ctrl.signal,
      });
      if (!r.ok) throw new Error(`commit failed (${r.status})`);
      const data = await r.json();
      setStatus(`Moved ${data.added} to “${data.album}” — review & delete in Photos.`);
    } catch (e) {
      const timedOut = e instanceof DOMException && e.name === "AbortError";
      setStatus(
        timedOut
          ? "Timed out — approve the “control Photos” prompt (System Settings → Privacy → Automation), then try again."
          : String(e),
      );
    } finally {
      clearTimeout(timer);
      setCommitting(false);
    }
  }

  if (error) return <div style={{ padding: 20, color: "crimson" }}>{error}</div>;

  const inCleanup = view !== "all";
  const flagged = Object.values(decisions).filter((d) => d === "delete").length;
  const columnCount = Math.max(1, Math.floor(width / CELL));
  const rowCount = Math.ceil(photos.length / columnCount);
  const gridHeight = height - HEADER_H - (status ? 30 : 0);

  const Tab = ({ v, label }: { v: View; label: string }) => (
    <button
      onClick={() => loadView(v)}
      disabled={view === v || loading}
      style={{
        padding: "4px 10px",
        borderRadius: 6,
        border: "1px solid #ccc",
        background: view === v ? "#0f0f0f" : "#fff",
        color: view === v ? "#fff" : "#0f0f0f",
        cursor: "pointer",
      }}
    >
      {label}
    </button>
  );

  return (
    <div style={{ display: "flex", flexDirection: "column", height: "100vh" }}>
      <header
        style={{
          display: "flex",
          gap: 8,
          alignItems: "center",
          padding: "8px 12px",
          borderBottom: "1px solid #ddd",
        }}
      >
        <Tab v="all" label="All" />
        <Tab v="screenshots" label="Screenshots" />
        <Tab v="low-quality" label="Low quality" />
        {inCleanup && !loading && (
          <>
            <span style={{ width: 1, height: 20, background: "#ddd" }} />
            <button
              onClick={() => setAll("keep")}
              style={{
                padding: "4px 10px",
                borderRadius: 6,
                border: "1px solid #ccc",
                background: "#fff",
                cursor: "pointer",
              }}
            >
              Keep all
            </button>
            <button
              onClick={() => setAll("delete")}
              style={{
                padding: "4px 10px",
                borderRadius: 6,
                border: "1px solid #ccc",
                background: "#fff",
                cursor: "pointer",
              }}
            >
              Delete all
            </button>
          </>
        )}
        <span style={{ marginLeft: "auto", fontWeight: 600 }}>
          {loading
            ? "Loading…"
            : inCleanup
              ? `${photos.length} candidates · ${flagged} to delete`
              : `${photos.length.toLocaleString()} photos`}
        </span>
        {inCleanup && !loading && (
          <button
            onClick={commit}
            disabled={committing || flagged === 0}
            style={{
              padding: "4px 12px",
              borderRadius: 6,
              border: "none",
              background: flagged === 0 ? "#ccc" : "#d33",
              color: "#fff",
              fontWeight: 600,
              cursor: flagged === 0 ? "default" : "pointer",
            }}
          >
            {committing ? "Moving…" : `Move ${flagged} → Delete Me album`}
          </button>
        )}
      </header>
      {status && (
        <div style={{ padding: "6px 12px", background: "#eef", fontSize: 13 }}>
          {status}
        </div>
      )}
      <div style={{ flex: 1, overflow: "hidden" }}>
        {!loading && width > 0 && (
          <FixedSizeGrid
            key={view}
            columnCount={columnCount}
            rowCount={rowCount}
            columnWidth={CELL}
            rowHeight={CELL}
            width={width}
            height={gridHeight}
          >
            {({ columnIndex, rowIndex, style }) => {
              const idx = rowIndex * columnCount + columnIndex;
              if (idx >= photos.length) return null;
              const ph = photos[idx];
              const dec = decisions[ph.uuid];
              const willDelete = inCleanup && dec === "delete";
              return (
                <div style={{ ...style, padding: 4, boxSizing: "border-box" }}>
                  <div
                    onClick={inCleanup ? () => toggle(ph.uuid) : undefined}
                    style={{
                      position: "relative",
                      width: "100%",
                      height: "100%",
                      cursor: inCleanup ? "pointer" : "default",
                    }}
                  >
                    <img
                      src={`http://127.0.0.1:${port}/thumb/${ph.uuid}`}
                      loading="lazy"
                      title={ph.filename}
                      style={{
                        width: "100%",
                        height: "100%",
                        objectFit: "cover",
                        borderRadius: 4,
                        background: "#eee",
                        opacity: willDelete ? 0.5 : 1,
                      }}
                    />
                    {inCleanup && (
                      <span
                        style={{
                          position: "absolute",
                          top: 6,
                          left: 6,
                          padding: "2px 6px",
                          borderRadius: 4,
                          fontSize: 12,
                          fontWeight: 600,
                          color: "#fff",
                          background: willDelete ? "#d33" : "#2a2",
                        }}
                      >
                        {willDelete ? "✗ Delete" : "✓ Keep"}
                      </span>
                    )}
                  </div>
                </div>
              );
            }}
          </FixedSizeGrid>
        )}
      </div>
    </div>
  );
}

export default App;
