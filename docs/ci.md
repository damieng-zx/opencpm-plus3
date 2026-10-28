# CI with zx84

This document records how the zx84 MCP server fits into the project’s CI flow
and what remains optional (packaging the server for other repositories).

## What zx84 needs

- **Node 22** (`mcp/server.ts` uses `import.meta.dirname` and runs through
  `tsx`; the repository’s deploy workflow already uses Node 22).
- **`npm ci`** in the zx84 checkout. `tsx` is a dev dependency, so
  `npx --no-install tsx mcp/server.ts` works after installation.
- **The +3 ROMs.** They are copyrighted and are *not* in the zx84 repository.
  `mcp/rom-fetch.ts` downloads the four `sinclair/plus3-*.rom` files from
  `https://zx84files.bitsparse.com/roms/` and caches them in
  `mcp/.cache/` (gitignored). CI must allow that host on the first run, or
  provide a warm `mcp/.cache` directory.
- **No display or terminal.** The MCP server is a stdio JSON-RPC process; the
  machine is headless. It does not need X11, a browser, or a PTY.

The smoke runner (`tools/zx84_smoke.py`) starts the server itself, so CI only
needs the checkout, `npm ci`, and a writable ROM cache.

## What the workflow does

`.github/workflows/ci.yml` has two jobs:

1. **build-test** — installs Python and sjasmplus, runs `./build.sh` and the
   static unit tests.
2. **emulator-test** — checks out zx84 into `zx84/`, runs `npm ci`, caches
   `zx84/mcp/.cache`, builds the DSK, then runs:
   - `python3 tools/zx84_smoke.py --zx84 zx84`
   - `python3 tools/zx84_negative.py --zx84 zx84`

`tools/install-sjasmplus.sh` clones the pinned `v1.21.0` tag into
`build/sjasmplus-src` and prints the binary path, so the workflow can set
`SJASMPLUS` without a Windows-specific path.

`references/binaries/` is untracked, so CI builds a source-only disk. The
smoke runner always exercises `SMOKE.TXT` (from `src/test/smoke.txt`),
`SMOKE.SUB` (from `src/test/smoke.sub`), `PARAM.SUB` (from
`src/test/param.sub`), the source-built `SUBMIT.COM`, `DATE.COM`, and the
built-in `ERA`/`REN` commands; only the external `RENAME.COM` and `PIP` checks
depend on the reference programs.

The zx84 checkout uses the current repository name,
`damieng-zx/zx84`. If it is private in a future org, add
`token: ${{ secrets.ZX84_TOKEN }}` to that `actions/checkout` step.

## Local equivalent

```bash
SJASMPLUS=$(tools/install-sjasmplus.sh) ./build.sh
python3 -m unittest discover -s tests -t .
python3 tools/zx84_smoke.py --zx84 ../zx84
python3 tools/zx84_negative.py --zx84 ../zx84
```

On Windows, keep using `build.cmd` and
`python tools\zx84_smoke.py --zx84 F:\src\zx\zx84`.

## Packaging options for zx84

We own zx84, so the setup can be published instead of duplicated in every
consumer’s workflow.

### 1. Composite action (recommended)

Add `.github/actions/setup-zx84-mcp/action.yml` in zx84:

```yaml
name: Setup zx84 MCP
description: Install zx84 dependencies and expose ZX84_DIR
runs:
  using: composite
  steps:
    - uses: actions/setup-node@v4
      with:
        node-version: '22'
    - run: npm ci
      shell: bash
      working-directory: ${{ github.action_path }}
    - run: echo "ZX84_DIR=${{ github.action_path }}" >> "$GITHUB_ENV"
      shell: bash
```

Consumers then use:

```yaml
- uses: damieng-zx/zx84/.github/actions/setup-zx84-mcp@main
- run: python3 tools/zx84_smoke.py --zx84 "$ZX84_DIR"
```

Advantages: versioned with zx84, no package registry, no extra checkout,
works with the same source tree. The ROM cache still lives under
`$ZX84_DIR/mcp/.cache`, which the caller can cache with `actions/cache`.
Composite actions do not share `node_modules` between jobs, so `npm ci` runs
once per job (about 20–40 seconds).

### 2. GHCR container image

Publish `ghcr.io/damieng-zx/zx84-mcp` containing Node, the zx84 source, and
`node_modules` (but **not** ROMs). Consumers run:

```yaml
- run: |
    docker run --rm -i \
      -v "$PWD/zx84-cache:/app/mcp/.cache" \
      -v "$PWD/build/cpm3.dsk:/cpm3.dsk:ro" \
      ghcr.io/damieng-zx/zx84-mcp \
      ...
```

This gives the most reproducible environment and removes Node setup from the
consumer, but adds image build/publish maintenance and a Docker dependency.
It is useful if several repositories need the emulator.

### 3. npm/GitHub Package

Publishing `@damieng-zx/zx84` to GitHub Packages is possible, but the current
`package.json` is `private`, has no `bin`/`exports`, and the MCP server imports
the TypeScript source directly. A publishable package needs:

- a `tsc` build of the MCP entry point (or a bundled `tsx` invocation),
- `bin`/`exports` entries,
- the browser build excluded from the package,
- a `publishConfig` for GitHub Packages,
- ROM fetching left as a runtime concern.

That is more work than a composite action and does not solve the ROM cache.
Use it only if non-GitHub CI consumers need an installable artifact.

## Caveats

- GitHub-hosted runners can reach the public ROM host; a locked-down
  self-hosted runner may need a pre-populated `zx84/mcp/.cache` or a mirror.
- ROMs must not be committed to either repository or baked into a public
  image.
- The workflow is intentionally a normal push/PR gate; `workflow_dispatch`
  allows a manual run. It has not been executed on GitHub Actions from this
  development machine, so the first run should be watched for
  network/ROM-cache and `npm ci` issues.
