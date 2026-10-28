# Contributing

## Setup

```bash
uv sync && pnpm install
pnpm build
```

`pnpm build` writes the UI into `photos_cleanup/ui/`. Git ignores that directory. The wheel includes it.

## Run

```bash
uv run photos-cleanup
```

For hot reload, run the API and Vite in two terminals.

```bash
uv run photos-cleanup --dev
pnpm dev
```

Vite proxies API requests to the server.

## Tests

```bash
uv run pytest -q
```

The tests mock the PhotoKit helper. They need no Photos library, no Photos access and no Swift toolchain.

## Pre-commit

```bash
pre-commit install
```

This installs a commit hook and a pre-push hook.
The commit hook runs the linters.
The pre-push hook runs pytest and `uv audit`.

## Layout

- `photos_cleanup/` — FastAPI server, library reads (`library.py`) and the Swift helpers
- `src/` — React UI
- `tests/` — server tests
- `spike/` — research probes

## Release

1. Bump `[project] version` in `pyproject.toml` on `master`.
2. CI tags `v<version>` and creates a GitHub Release.
3. The publish workflow builds the UI, the sdist, and the wheel.
4. The workflow publishes to PyPI with Trusted Publishing.
5. The workflow updates the Homebrew tap formula to the new sdist.
