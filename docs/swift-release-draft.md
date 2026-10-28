# Swift release pipeline: DRAFT

Nothing here is applied. A human replaces the files below (a hook blocks automated edits to `.github/`).
Action versions are copied from the current workflows (`checkout@v7`, `pnpm/action-setup@v6`, `setup-node@v7`, `mislav/bump-homebrew-formula-action@v4`).

## 1. `.github/workflows/ci.yml`

Drops uv, pre-commit and pytest. The old file ran pre-commit; if `.pre-commit-config.yaml` survives the Python removal (prettier, tsc and similar), keep a pre-commit step. That is not decided here.

```yaml
name: ci

on:
  push:
    branches: [master]
  pull_request:

permissions:
  contents: read

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

jobs:
  ci:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v7

      # package.json has no `packageManager`, so pin the major here.
      - uses: pnpm/action-setup@v6
        with:
          version: 10

      - uses: actions/setup-node@v7
        with:
          node-version: 22
          cache: pnpm

      - run: pnpm install --frozen-lockfile

      # Writes the UI to Sources/PhotosCleanup/ui/dist. Package.swift has
      # `.copy("ui")`, so swift build needs it to exist first.
      - run: pnpm build

      - name: UI was built
        run: test -f Sources/PhotosCleanup/ui/dist/index.html

      - run: swift build
      - run: swift test
```

## 2. `.github/workflows/release.yml` (replaces `tag.yml` and `publish.yml`)

One merged workflow, because the old split existed for two Python reasons that no longer apply:

- `tag.yml` pushed the tag with the PAT so that `publish.yml` would fire (GITHUB_TOKEN refs do not trigger workflows).
- PyPI refused re-uploads, so tagging and publishing had to be separate and idempotent.

Now one job on a push to master that touches `main.swift` can check the tag, build, and create the release. `gh release create` creates the tag itself, so no PAT is needed for the tag. `HOMEBREW_TAP_TOKEN` is still needed for the tap bump.

The `paths` filter fires on any edit to `main.swift`, not only on a version change. The `gh release view` guard makes that harmless.

```yaml
name: release

# When a commit to master changes `let version` in main.swift: build a
# universal binary + the SwiftPM resource bundle, tar them, create the GitHub
# Release v<version> with the tarball attached, then bump the Homebrew tap.
#
# Idempotent: if release v<version> exists, the whole job after the check is
# skipped. To redo a release, delete the release and the tag first.
#
# Repo secret HOMEBREW_TAP_TOKEN (the fine-grained PAT shared with cockpit)
# is used only for the tap bump. It needs Contents: write on
# khivi/homebrew-photos-cleanup.

on:
  push:
    branches: [master]
    paths: ["Sources/PhotosCleanup/main.swift"]

permissions:
  contents: read

concurrency:
  group: release
  cancel-in-progress: false

jobs:
  release:
    runs-on: macos-latest
    permissions:
      contents: write # create the tag and Release with GITHUB_TOKEN
    steps:
      - uses: actions/checkout@v7

      - name: Read version and skip if already released
        id: ver
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          v="$(sed -n 's/^let version = "\(.*\)"$/\1/p' Sources/PhotosCleanup/main.swift)"
          if [ -z "$v" ]; then
            echo "::error::could not read 'let version' from main.swift"
            exit 1
          fi
          echo "version=$v" >> "$GITHUB_OUTPUT"
          if gh release view "v$v" >/dev/null 2>&1; then
            echo "release v$v already exists"
            echo "skip=true" >> "$GITHUB_OUTPUT"
          else
            echo "skip=false" >> "$GITHUB_OUTPUT"
          fi

      # package.json has no `packageManager`, so pin the major here.
      - if: steps.ver.outputs.skip == 'false'
        uses: pnpm/action-setup@v6
        with:
          version: 10

      - if: steps.ver.outputs.skip == 'false'
        uses: actions/setup-node@v7
        with:
          node-version: 22
          cache: pnpm

      - if: steps.ver.outputs.skip == 'false'
        run: pnpm install --frozen-lockfile

      - if: steps.ver.outputs.skip == 'false'
        run: pnpm build

      # The UI is gitignored; without this check a release that skipped
      # `pnpm build` would ship a binary that serves a blank page.
      - name: UI was built
        if: steps.ver.outputs.skip == 'false'
        run: test -f Sources/PhotosCleanup/ui/dist/index.html

      - name: Build universal release binary
        if: steps.ver.outputs.skip == 'false'
        run: swift build -c release --arch arm64 --arch x86_64

      - name: Package tarball
        if: steps.ver.outputs.skip == 'false'
        id: pkg
        env:
          V: ${{ steps.ver.outputs.version }}
        run: |
          bin="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
          ls "$bin"
          test -d "$bin/photos-cleanup_PhotosCleanup.bundle"
          test -f "$bin/photos-cleanup_PhotosCleanup.bundle/ui/dist/index.html" \
            || test -f "$bin/photos-cleanup_PhotosCleanup.bundle/Contents/Resources/ui/dist/index.html"
          lipo -archs "$bin/photos-cleanup"
          out="photos-cleanup-$V-macos-universal.tar.gz"
          tar -czf "$out" -C "$bin" photos-cleanup photos-cleanup_PhotosCleanup.bundle
          echo "tarball=$out" >> "$GITHUB_OUTPUT"
          "$bin/photos-cleanup" --version | grep -q "$V"

      - name: Create tag and GitHub Release
        if: steps.ver.outputs.skip == 'false'
        env:
          GH_TOKEN: ${{ github.token }}
          V: ${{ steps.ver.outputs.version }}
          TARBALL: ${{ steps.pkg.outputs.tarball }}
        run: |
          gh release create "v$V" "$TARBALL" \
            --target "$GITHUB_SHA" --title "v$V" --generate-notes

      - name: Bump Homebrew tap
        if: steps.ver.outputs.skip == 'false'
        uses: mislav/bump-homebrew-formula-action@v4
        with:
          formula-name: photos-cleanup
          homebrew-tap: khivi/homebrew-photos-cleanup
          tag-name: v${{ steps.ver.outputs.version }}
          download-url: https://github.com/${{ github.repository }}/releases/download/v${{ steps.ver.outputs.version }}/${{ steps.pkg.outputs.tarball }}
          create-branch: false
        env:
          COMMITTER_TOKEN: ${{ secrets.HOMEBREW_TAP_TOKEN }}
```

## 3. Homebrew formula `Formula/photos-cleanup.rb` in `khivi/homebrew-photos-cleanup`

Recommendation: install the prebuilt tarball.

A source build needs a full Xcode and the macOS 27 SDK, because `PhotosCleanupCore/Verdicts.swift` imports `FoundationModels`. It also needs pnpm and Node plus a SwiftPM dependency fetch (Hummingbird and its tree) at install time, which can take minutes and breaks under brew's sandbox. The tarball install is seconds, needs no toolchain, and matches the binary CI tested.

The cost is that the binary is built by CI, not brew. The formula is only a url, a sha256 and a wrapper.

```ruby
# Homebrew formula for photos-cleanup.
#
# Install:  brew tap khivi/photos-cleanup && brew install photos-cleanup
# Update:   brew upgrade photos-cleanup
#
# url and sha256 are bumped by the release workflow in khivi/photos-cleanup
# on every release.
class PhotosCleanup < Formula
  desc "Review and clear unwanted photos in the macOS Photos library"
  homepage "https://github.com/khivi/photos-cleanup"
  url "https://github.com/khivi/photos-cleanup/releases/download/v0.3.0/photos-cleanup-0.3.0-macos-universal.tar.gz"
  sha256 "REPLACE_WITH_SHA256_OF_THE_0.3.0_TARBALL"
  license "MIT"

  depends_on :macos
  # Package.swift: platforms: [.macOS(.v15)]. The FoundationModels judge may
  # need newer; see uncertainty 3 in swift-release-draft.md.
  depends_on macos: :sequoia

  def install
    # Keep the binary and the SwiftPM resource bundle side by side: the
    # generated Bundle.module looks for photos-cleanup_PhotosCleanup.bundle
    # next to the executable.
    libexec.install "photos-cleanup", "photos-cleanup_PhotosCleanup.bundle"
    # A wrapper that execs the real libexec path (not a symlink), so
    # Bundle.main resolves to libexec rather than bin.
    bin.write_exec_script libexec/"photos-cleanup"
  end

  def caveats
    <<~EOS
      Grant Full Disk Access to your terminal (System Settings > Privacy &
      Security > Full Disk Access) so photos-cleanup can read the Photos library.
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/photos-cleanup --version")
  end
end
```

Source-build alternative, if you prefer it. Not recommended; untested:

```ruby
  depends_on xcode: ["16.0", :build]
  depends_on "node" => :build
  depends_on "pnpm" => :build

  def install
    system "pnpm", "install", "--frozen-lockfile"
    system "pnpm", "build"
    system "swift", "build", "-c", "release", "--disable-sandbox"
    bin_path = Utils.safe_popen_read("swift", "build", "-c", "release", "--show-bin-path").chomp
    libexec.install "#{bin_path}/photos-cleanup", "#{bin_path}/photos-cleanup_PhotosCleanup.bundle"
    bin.write_exec_script libexec/"photos-cleanup"
  end
```

The source build needs the GitHub tag tarball to contain `pnpm-lock.yaml`. It does not contain the built UI, but `pnpm build` makes it.

## 4. `.github/dependabot.yml`

The old file had both a `uv` entry and a `pip` entry. The `pip` entry only read `.pre-commit-config.yaml` pins. Both are replaced here by `swift`. If pre-commit stays, keep the `pip` entry as it was.

```yaml
version: 2

# 7-day cooldown on every entry: a compromised release is usually yanked within
# days, so the delay costs nothing at a monthly interval.
updates:
  # Package.swift / Package.resolved (Hummingbird and its tree).
  - package-ecosystem: swift
    directory: "/"
    schedule:
      interval: monthly
    open-pull-requests-limit: 5
    cooldown:
      default-days: 7

  - package-ecosystem: npm
    directory: "/"
    schedule:
      interval: monthly
    open-pull-requests-limit: 5
    cooldown:
      default-days: 7
    # react and react-dom must match exactly; split PRs leave a blank page (React error #527).
    groups:
      react:
        patterns: ["react", "react-dom", "@types/react", "@types/react-dom"]

  # Action versions in .github/workflows/*.yml
  - package-ecosystem: github-actions
    directory: "/"
    schedule:
      interval: monthly
    open-pull-requests-limit: 5
    cooldown:
      default-days: 7
```

## 5. Human checklist

Files to replace or delete:

- [ ] Replace `.github/workflows/ci.yml` (section 1).
- [ ] Add `.github/workflows/release.yml` (section 2). `git rm .github/workflows/tag.yml .github/workflows/publish.yml`.
- [ ] Replace `.github/dependabot.yml` (section 4).
- [ ] In `khivi/homebrew-photos-cleanup`, replace `Formula/photos-cleanup.rb` (section 3). Fill in the real sha256 after the first release. The bump action then keeps url and sha256 current.
- [ ] Update the CONTRIBUTING.md "Release" section: bump `let version` in `Sources/PhotosCleanup/main.swift` on master, CI builds the tarball, creates the tag and Release, and bumps the tap.
- [ ] Remove the stale comment in `Package.swift` or CONTRIBUTING.md that still says "wheel" or "hatch", if any survives the Python removal.

PyPI and secrets:

- [ ] Archive or deprecate `macos-photos-cleanup` on PyPI: publish a final version whose README points to the Homebrew install, then mark the project as archived. PyPI cannot delete a version that people may pin, so do not delete it.
- [ ] Delete the `pypi` GitHub environment (Settings > Environments) and remove the pending or active Trusted Publisher entry for `publish.yml` on PyPI.
- [ ] `HOMEBREW_TAP_TOKEN` is still used (tap bump only). Its scope can shrink: it no longer needs Contents: write on `khivi/photos-cleanup`, only on the tap repo. The cockpit repo shares it, so check that before narrowing.
- [ ] `GITHUB_TOKEN` is the only credential for tag and Release. No new secrets.

## Uncertainties

Status after review (2026-10-28): 1 and 3 are fixed in code; 9 is fine (`Package.resolved` is tracked). One more item, 10, was found while building.

1. **FIXED in `main.swift`:** the UI is now found via `Bundle.main.executableURL` (symlinks resolved) + `photos-cleanup_PhotosCleanup.bundle`, never `Bundle.module`; a missing bundle prints the "web UI is missing" error instead of trapping. Still worth a clean-machine `brew install` check. Original note: **Resource bundle from a Homebrew libexec install.** The SwiftPM-generated `Bundle.module` for an executable looks at `Bundle.main.bundleURL/photos-cleanup_PhotosCleanup.bundle`, and falls back to the absolute build-directory path baked in at compile time. On a CI-built tarball that fallback path does not exist on the user's machine, so the lookup must hit the first path. For a bare executable `Bundle.main.bundleURL` is the executable's directory. Whether it resolves symlinks is unverified, which is why the formula uses `write_exec_script` (a wrapper that execs the libexec path) rather than a `bin` symlink. Verify on a clean machine: `brew install`, run `photos-cleanup`, and confirm the UI loads. If it fails, add a fallback in `main.swift` line 50 (`let uiDir = Bundle.module...`). Note the failure mode there: `Bundle.module` traps (fatalError) when the bundle is missing, so a fallback has to avoid touching `Bundle.module` at all, for example by resolving `CommandLine.arguments[0]` or `Bundle.main.executableURL` and reading `<dir>/photos-cleanup_PhotosCleanup.bundle` itself.
2. **Bundle layout and the resource check.** Whether `.copy("ui")` puts files at `<bundle>/ui/dist/...` or `<bundle>/Contents/Resources/ui/dist/...` depends on the SwiftPM version. The packaging step accepts either, but the app's own lookup (`withExtension: nil` then `/dist`) is what matters, so check it with a local release build.
3. **FIXED in `Verdicts.swift`:** FoundationModels is compiled only with `#if canImport(FoundationModels, _version: 2.0)` (the macOS 27 SDK's module version). An older SDK builds and tests fine and reports verdicts unavailable at runtime, so CI on `macos-latest` should pass; **release builds must use the macOS 27 SDK or ship without verdicts.** Original note: **FoundationModels on the runner.** `Verdicts.swift` imports `FoundationModels` unconditionally. The old ci.yml skipped `swift-typecheck` because `macos-latest` lacked the macOS 27 SDK. If that is still true, `swift build` and `swift test` will fail in CI and in the release job. Options: pin a runner image with the SDK, guard the import with `#if canImport(FoundationModels)`, or build the release locally. I did not verify the current runner's SDK.
4. **`depends_on macos: :sequoia`.** Matches `.macOS(.v15)`, but the FoundationModels API may require a higher OS at runtime. A minimum of macOS 26 or 27 may be right; I did not check this.
5. **Universal build.** `--arch arm64 --arch x86_64` uses the Xcode build system and puts products under `.build/apple/Products/Release`, which is why the workflow asks `--show-bin-path`. `unsafeFlags` with the relative `Sources/PhotosCleanup/Info.plist` path assumes the build runs from the repo root, which it does. If the x86_64 slice fails (Hummingbird or the SDK), fall back to `--arch arm64` and change the tarball suffix to `macos-arm64`; the formula then needs `depends_on arch: :arm64`.
6. **Code signing and Gatekeeper.** The binary is ad-hoc signed by the linker only. A `curl` download by brew sets no quarantine flag, so it runs. A manual browser download of the tarball would be quarantined and blocked. If Photos permission prompts misbehave without a proper identity, a signed or notarized build is needed. I did not test this.
7. **`mislav/bump-homebrew-formula-action@v4` with a non-archive URL.** It is given `download-url` explicitly, as the old workflow did, and it downloads the file to compute the sha256. It also needs the release asset to be live; the step runs after `gh release create`, so it is. I did not run it. Its `tag-name` input is passed to name the commit and derive the version.
8. **`paths` filter on `main.swift`.** It also fires on non-version edits. The `gh release view` skip makes this harmless, but a version bump committed together with a broken build fails the release job with no release created; a re-run after the fix is the recovery.
9. **swift dependabot ecosystem.** It needs `Package.resolved` committed to resolve versions precisely; check that it is tracked.
10. **Ship every `.bundle`, not just ours.** `swift build` also produces `swift-nio_NIOPosix.bundle`, `swift-nio__NIOFileSystem.bundle` and `swift-nio-ssl_NIOSSL.bundle` (Hummingbird's networking dependencies). Those libraries look up their own bundles via `Bundle.module`, which traps if missing. The release tarball and the formula must copy all `*.bundle` from the bin path next to the binary.
