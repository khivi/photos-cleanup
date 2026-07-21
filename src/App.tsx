import { useEffect, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { FixedSizeGrid } from "react-window";
import "./App.css";

type Photo = { uuid: string; filename: string; is_video: boolean };

const CELL = 170; // px per thumbnail cell
const HEADER_H = 38; // header height in px

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
  const [photos, setPhotos] = useState<Photo[]>([]);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      const p = await invoke<number>("sidecar_port");
      if (!cancelled) setPort(p);
      // Sidecar may still be booting / loading the library; retry ~2 min.
      for (let i = 0; i < 120 && !cancelled; i++) {
        try {
          const r = await fetch(`http://127.0.0.1:${p}/photos?limit=100000`);
          if (r.ok) {
            const data = await r.json();
            if (!cancelled) setPhotos(data.photos);
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

  const { width, height } = useWindowSize();

  if (error) return <div style={{ padding: 20, color: "crimson" }}>{error}</div>;
  if (!port || photos.length === 0)
    return <div style={{ padding: 20 }}>Loading library…</div>;

  const columnCount = Math.max(1, Math.floor(width / CELL));
  const rowCount = Math.ceil(photos.length / columnCount);
  const gridHeight = height - HEADER_H;

  return (
    <div style={{ display: "flex", flexDirection: "column", height: "100vh" }}>
      <header
        style={{
          padding: "8px 12px",
          fontWeight: 600,
          borderBottom: "1px solid #ddd",
        }}
      >
        Photo Cleanup · {photos.length.toLocaleString()} photos
      </header>
      <div style={{ flex: 1, overflow: "hidden" }}>
        {width > 0 && (
          <FixedSizeGrid
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
              return (
                <div style={{ ...style, padding: 4, boxSizing: "border-box" }}>
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
                    }}
                  />
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
