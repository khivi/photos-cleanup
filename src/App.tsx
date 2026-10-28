import { type CSSProperties, type ReactElement, useEffect, useRef, useState } from "react";
import { type CellComponentProps, Grid, List, type RowComponentProps } from "react-window";
import "./App.css";

type Verdict = { keep: boolean; kind: string; reason: string };
type Photo = {
  uuid: string;
  is_video: boolean;
  verdict?: Verdict | null;
  best?: boolean; // bursts: the highest-scored photo of the group
};
type Classify = { pending: number; total?: number; error: string | null };
// A pass's view key and tab label match the server's PASSES (and its albums' prefix).
type View = "all" | "screenshots" | "utility" | "bursts" | "low-quality" | "deleted";
type Decision = "keep" | "delete";
const CLEANUP_VIEWS: View[] = ["screenshots", "utility", "bursts", "low-quality"];
const VERDICT_VIEWS: View[] = ["screenshots", "utility"]; // judged by the on-device model

const CELL = 170; // px per thumbnail cell
const POLL_MS = 5000; // refresh while the server analyses or classifies in the background

/** Burst rows from /cleanup/bursts, each photo flagged with whether it's its group's best. */
function groupsOf(data: { groups: { photos: Photo[]; best: string }[] }): Photo[][] {
  return data.groups.map((g) => g.photos.map((p) => ({ ...p, best: p.uuid === g.best })));
}

function initialDecision(v: View, p: Photo): Decision {
  if (v === "bursts") return p.best ? "keep" : "delete";
  if (!VERDICT_VIEWS.includes(v)) return "delete";
  return p.verdict && !p.verdict.keep ? "delete" : "keep";
}

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

// react-window v2 takes cell/row components, not render functions. They live at
// module level: defined inside App they'd be new each render and remount every cell.
type CellFn = (ph: Photo, style: CSSProperties) => ReactElement;

function GridCell({
  columnIndex,
  rowIndex,
  style,
  displayed,
  columnCount,
  cell,
}: CellComponentProps<{ displayed: Photo[]; columnCount: number; cell: CellFn }>) {
  const idx = rowIndex * columnCount + columnIndex;
  return idx < displayed.length ? cell(displayed[idx], style) : null;
}

function GroupRow({ index, style, groups, cell }: RowComponentProps<{ groups: Photo[][]; cell: CellFn }>) {
  return (
    <div style={{ ...style, display: "flex", overflowX: "auto" }}>
      {groups[index].map((ph) => (
        <div key={ph.uuid} style={{ flex: "none", width: CELL, height: CELL }}>
          {cell(ph, { width: "100%", height: "100%" })}
        </div>
      ))}
    </div>
  );
}

function App() {
  const [view, setView] = useState<View>("all");
  const [photos, setPhotos] = useState<Photo[]>([]);
  const [deleted, setDeleted] = useState<Photo[]>([]); // queued-for-deletion this session
  const [groups, setGroups] = useState<Photo[][]>([]); // bursts view: one row per burst
  const [decisions, setDecisions] = useState<Record<string, Decision>>({});
  const [touched, setTouched] = useState<Set<string>>(new Set()); // decided explicitly by the user
  const touchedRef = useRef(touched);
  touchedRef.current = touched;
  const [classify, setClassify] = useState<Classify>({ pending: 0, error: null });
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [committing, setCommitting] = useState(false);
  const [status, setStatus] = useState<string | null>(null);
  const [counts, setCounts] = useState<Partial<Record<View, number | null>>>({});
  const { width, height } = useWindowSize();
  // The toolbar wraps on narrow windows; the grid sizes itself from its measured height.
  const headerRef = useRef<HTMLElement>(null);
  const [headerH, setHeaderH] = useState(46);
  useEffect(() => {
    const el = headerRef.current;
    if (!el) return;
    const ro = new ResizeObserver(() => setHeaderH(el.offsetHeight));
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

  // Tab counts change after a load, a commit, or a classification run finishing.
  useEffect(() => {
    if (loading || committing) return;
    fetch("/counts")
      .then((r) => (r.ok ? r.json() : null))
      .then((c) => c && setCounts(c))
      .catch(() => {});
  }, [loading, committing, classify.pending === 0]);

  // Boot: wait for the same-origin server to answer, then load the full library.
  useEffect(() => {
    let cancelled = false;
    (async () => {
      for (let i = 0; i < 120 && !cancelled; i++) {
        try {
          const r = await fetch("/photos");
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

  // Poll while the server analyses (Vision) or classifies (verdicts) in the background.
  const polling = CLEANUP_VIEWS.includes(view) && classify.pending > 0;
  useEffect(() => {
    if (!polling) return;
    let cancelled = false;
    const timer = setInterval(async () => {
      try {
        const r = await fetch(`/cleanup/${view}`);
        if (!r.ok) return;
        const data = await r.json();
        if (cancelled) return;
        if (view === "bursts") {
          // Bursts regroup as more photos are analysed, so take the new rows wholesale.
          const gs = groupsOf(data);
          setGroups(gs);
          data.photos = gs.flat();
        }
        const fresh = new Map<string, Photo>(data.photos.map((p: Photo) => [p.uuid, p]));
        // Candidates appear as they're analysed or classified, so merge new ones in.
        if (view === "bursts") setPhotos(data.photos);
        else setPhotos((prev) => {
          const have = new Set(prev.map((p) => p.uuid));
          const added = data.photos.filter((p: Photo) => !have.has(p.uuid));
          return [
            ...prev.map((p) => (fresh.has(p.uuid) ? { ...p, verdict: fresh.get(p.uuid)!.verdict } : p)),
            ...added,
          ];
        });
        setDecisions((prev) => {
          const next = { ...prev };
          for (const [id, p] of fresh)
            if (!touchedRef.current.has(id)) next[id] = initialDecision(view, p);
          return next;
        });
        setClassify(data.classify);
      } catch {
        /* retry next tick */
      }
    }, POLL_MS);
    return () => {
      cancelled = true;
      clearInterval(timer);
    };
  }, [polling, view]);

  async function loadView(v: View) {
    setStatus(null);
    // "deleted" is a client-side view of what we queued this session — no fetch.
    if (v === "deleted") {
      setView(v);
      return;
    }
    setLoading(true);
    try {
      const path = v === "all" ? "/photos" : `/cleanup/${v}`;
      const r = await fetch(path);
      const data = await r.json();
      if (v === "bursts") {
        const gs = groupsOf(data);
        data.photos = gs.flat();
        setGroups(gs);
      }
      setPhotos(data.photos);
      setView(v);
      // Cleanup candidates start per initialDecision; user toggles.
      const next: Record<string, Decision> = {};
      if (CLEANUP_VIEWS.includes(v)) for (const p of data.photos) next[p.uuid] = initialDecision(v, p);
      setDecisions(next);
      setTouched(new Set());
      setClassify(data.classify ?? { pending: 0, error: null });
    } finally {
      setLoading(false);
    }
  }

  function toggle(uuid: string) {
    setTouched((prev) => new Set(prev).add(uuid));
    setDecisions((prev) => ({
      ...prev,
      [uuid]: prev[uuid] === "delete" ? "keep" : "delete",
    }));
  }

  function setAll(d: Decision) {
    const next: Record<string, Decision> = {};
    for (const p of photos) next[p.uuid] = d;
    setDecisions(next);
    setTouched(new Set(photos.map((p) => p.uuid)));
  }

  const doomed = photos.filter((p) => decisions[p.uuid] === "delete");
  const keepers = photos.filter(
    (p) => decisions[p.uuid] === "keep" && (touched.has(p.uuid) || p.verdict || p.best),
  );

  async function commit() {
    if (!CLEANUP_VIEWS.includes(view)) return;
    const uuids = doomed.map((p) => p.uuid);
    const keep = keepers.map((p) => p.uuid);
    if (uuids.length === 0 && keep.length === 0) return;
    setCommitting(true);
    setStatus(null);
    // The first commit triggers macOS's Photos access prompt; if it isn't
    // answered the request blocks. Time out so the UI never hangs forever.
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), 90_000);
    try {
      const r = await fetch("/commit", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ kind: view, uuids, keep }),
        signal: ctrl.signal,
      });
      if (!r.ok) {
        const detail = await r.json().then((d) => d.detail, () => null);
        throw new Error(detail ?? `commit failed (${r.status})`);
      }
      const data = await r.json();
      // Refresh: pull the moved photos out of the candidate grid and into the
      // "To be deleted" tab (dedupe by uuid).
      const gone = new Set([...uuids, ...keep]);
      setDeleted((prev) => {
        const seen = new Set(prev.map((p) => p.uuid));
        return [...doomed.filter((p) => !seen.has(p.uuid)), ...prev];
      });
      setPhotos((prev) => prev.filter((p) => !gone.has(p.uuid)));
      setGroups((prev) => prev.map((g) => g.filter((p) => !gone.has(p.uuid))).filter((g) => g.length));
      setDecisions((prev) => {
        const next = { ...prev };
        for (const id of gone) delete next[id];
        return next;
      });
      setTouched((prev) => new Set([...prev].filter((id) => !gone.has(id))));
      const parts = [];
      if (data.added) parts.push(`${data.added} to “${data.album}”`);
      if (data.kept) parts.push(`${data.kept} to “${data.keep_album}”`);
      setStatus(`Moved ${parts.join(", ")}.`);
    } catch (e) {
      const timedOut = e instanceof DOMException && e.name === "AbortError";
      setStatus(
        timedOut
          ? "Timed out — a Photos access prompt may be waiting for an answer. Try again; re-adding is safe."
          : e instanceof Error ? e.message : String(e),
      );
    } finally {
      clearTimeout(timer);
      setCommitting(false);
    }
  }

  if (error) return <div style={{ padding: 20, color: "crimson" }}>{error}</div>;

  const inCleanup = CLEANUP_VIEWS.includes(view);
  const displayed = view === "deleted" ? deleted : photos;
  const flagged = doomed.length;
  const kept = keepers.length;
  const canCommit = flagged > 0 || kept > 0;
  const columnCount = Math.max(1, Math.floor(width / CELL));
  const rowCount = Math.ceil(displayed.length / columnCount);
  const banner =
    view === "deleted"
      ? "Nothing is deleted yet. These photos were moved this session to the pass’s “Delete Me” album — open it in Photos, select all, and delete. This list resets on reload."
      : status;
  const gridHeight = height - headerH - (banner ? 30 : 0);

  const Tab = ({ v, label }: { v: View; label: string }) => {
    const n = v === "deleted" ? deleted.length || null : counts[v];
    return (
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
        whiteSpace: "nowrap",
      }}
    >
      {n == null ? label : `${label} (${n.toLocaleString()})`}
    </button>
    );
  };

  const bulkBtn = (color: string): CSSProperties => ({
    whiteSpace: "nowrap",
    padding: "4px 10px",
    borderRadius: 6,
    border: `1px solid ${color}`,
    background: "#fff",
    color,
    fontWeight: 600,
    cursor: "pointer",
  });

  const cell = (ph: Photo, style: CSSProperties) => {
    const isDeletedView = view === "deleted";
    const willDelete = inCleanup && decisions[ph.uuid] === "delete";
    const dim = willDelete || isDeletedView;
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
            src={`/thumb/${ph.uuid}`}
            loading="lazy"
            title={ph.verdict ? `${ph.verdict.kind}: ${ph.verdict.reason}` : undefined}
            style={{
              width: "100%",
              height: "100%",
              objectFit: "cover",
              borderRadius: 4,
              background: "#eee",
              opacity: dim ? 0.5 : 1,
            }}
          />
          {(inCleanup || isDeletedView) && (
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
                background: dim ? "#d33" : "#2a2",
              }}
            >
              {isDeletedView
                ? "✗ Delete Me"
                : willDelete
                  ? "✗ Delete"
                  : "✓ Keep"}
            </span>
          )}
          {inCleanup && ph.verdict && (
            <span
              style={{
                position: "absolute",
                bottom: 6,
                left: 6,
                padding: "1px 5px",
                borderRadius: 4,
                fontSize: 11,
                color: "#fff",
                background: "rgba(0,0,0,0.6)",
              }}
            >
              {ph.verdict.kind}
            </span>
          )}
        </div>
      </div>
    );
  };

  return (
    <div style={{ display: "flex", flexDirection: "column", height: "100vh" }}>
      <header
        ref={headerRef}
        style={{
          display: "flex",
          flexWrap: "wrap",
          gap: 8,
          alignItems: "center",
          padding: "8px 12px",
          borderBottom: "1px solid #ddd",
        }}
      >
        <Tab v="all" label="All" />
        <Tab v="screenshots" label="Screenshots" />
        <Tab v="utility" label="Utility" />
        <Tab v="bursts" label="Bursts" />
        <Tab v="low-quality" label="Low Quality" />
        <Tab
          v="deleted"
          label="To be deleted"
        />
        {inCleanup && !loading && (
          <>
            <span style={{ width: 1, height: 22, background: "#ddd", margin: "0 2px" }} />
            <span style={{ fontSize: 12, color: "#666", whiteSpace: "nowrap" }}>Select all:</span>
            <button onClick={() => setAll("keep")} style={bulkBtn("#2a2")}>
              ✓ Keep
            </button>
            <button onClick={() => setAll("delete")} style={bulkBtn("#d33")}>
              ✗ Delete
            </button>
          </>
        )}
        <span style={{ marginLeft: "auto", fontWeight: 600, whiteSpace: "nowrap" }}>
          {inCleanup && !loading && classify.pending > 0 && (
            <span style={{ fontWeight: 400, fontSize: 12, color: "#666", marginRight: 10 }}>
              <progress
                title="Analysing photos on this Mac; results appear as they arrive"
                value={(classify.total ?? 0) - classify.pending}
                max={classify.total || classify.pending}
                style={{ width: 120, verticalAlign: "middle", marginRight: 6 }}
              />
              {((classify.total ?? 0) - classify.pending).toLocaleString()}/
              {(classify.total || classify.pending).toLocaleString()}
            </span>
          )}
          {!loading && classify.error && (
            <span style={{ fontWeight: 400, fontSize: 12, color: "crimson", marginRight: 10 }}>
              {view === "bursts" ? "Similarity check unavailable" : "AI verdicts unavailable"}:{" "}
              {classify.error}
            </span>
          )}
          {loading
            ? "Loading…"
            : view === "deleted"
              ? `${deleted.length} queued for deletion`
              : inCleanup
                ? `${photos.length} candidates · ${flagged} to delete`
                : `${photos.length.toLocaleString()} photos`}
        </span>
        {inCleanup && !loading && (
          <button
            onClick={commit}
            disabled={committing || !canCommit}
            style={{
              padding: "4px 12px",
              borderRadius: 6,
              border: "none",
              background: canCommit ? "#d33" : "#ccc",
              color: "#fff",
              fontWeight: 600,
              cursor: canCommit ? "pointer" : "default",
              whiteSpace: "nowrap",
            }}
          >
            {committing ? "Moving…" : `Commit: ${flagged} delete · ${kept} keep`}
          </button>
        )}
      </header>
      {banner && (
        <div style={{ padding: "6px 12px", background: "#eef", fontSize: 13 }}>
          {banner}
        </div>
      )}
      <div style={{ flex: 1, overflow: "hidden" }}>
        {!loading && inCleanup && displayed.length === 0 && (
          <div style={{ padding: 40, textAlign: "center", color: "#666" }}>
            Nothing left to review. Photos already filed in this pass’s albums are hidden.
          </div>
        )}
        {!loading && width > 0 && view === "bursts" && (
          <List
            rowComponent={GroupRow}
            rowProps={{ groups, cell }}
            rowCount={groups.length}
            rowHeight={CELL}
            style={{ width, height: gridHeight }}
          />
        )}
        {!loading && width > 0 && view !== "bursts" && (
          <Grid
            key={view}
            cellComponent={GridCell}
            cellProps={{ displayed, columnCount, cell }}
            columnCount={columnCount}
            rowCount={rowCount}
            columnWidth={CELL}
            rowHeight={CELL}
            style={{ width, height: gridHeight }}
          />
        )}
      </div>
    </div>
  );
}

export default App;
