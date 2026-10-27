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

The tests mock PhotosDB. They need no Photos library and no Full Disk Access.

## Pre-commit

```bash
pre-commit install
```

This installs a commit hook and a pre-push hook.
The commit hook runs the linters.
The pre-push hook runs pytest and `uv audit`.

## Layout

- `photo_cleanup/` — vendored engine
- `photos_cleanup/` — FastAPI server and the Swift verdict helper
- `src/` — React UI
- `tests/` — server tests
- `spike/` — research probes

## Vendored engine

The engine in `./photo_cleanup` is the source of truth in this repo.
It started as a copy of an upstream project.
Edit it here. Do not import or depend on the upstream repo.

## Release

1. Bump `[project] version` in `pyproject.toml` on `master`.
2. CI tags `v<version>` and creates a GitHub Release.
3. The publish workflow builds the UI, the sdist, and the wheel.
4. The workflow publishes to PyPI with Trusted Publishing.
5. The workflow updates the Homebrew tap formula to the new sdist.
