# Releasing from GitHub Actions (split / merge)

No single machine can build every binary: darwin needs a macOS runner, and a
static Linux binary needs musl, which only the docker strategy provides on a
standard runner. The release is therefore split:

1. each runner runs `crystalreleaser build --split`, which builds only the
   platforms that host can produce and writes them, with a partial
   `artifacts.json`, under `dist/<os>_<arch>/`;
2. the runners upload their `dist/` with `actions/upload-artifact`;
3. a final job downloads everything back into `dist/` and runs
   `crystalreleaser release --merge`, which checks that every configured
   platform is there and that all of them come from the same commit, then
   archives, checksums, writes the changelog and publishes — without
   compiling anything.

The config this workflow assumes (abridged):

```yaml
builds:
  - id: myapp
    target: myapp
    flags: [--release, --no-debug]
    env:
      - MYAPP_VERSION={{ .Version }}
    platforms:
      - { os: linux,  arch: amd64, strategy: docker, static: true }
      - { os: linux,  arch: arm64, strategy: docker, static: true }
      - { os: darwin, arch: arm64, strategy: native }
      - { os: darwin, arch: amd64, strategy: native }
```

On `ubuntu-24.04`, `build --split` takes both docker platforms (arm64 through
QEMU, hence the `setup-qemu-action` step) and leaves the darwin ones. On the
macOS runners it takes the native platform matching the runner and leaves the
rest. `--os`/`--arch` override this choice when a runner should take a precise
share.

```yaml
name: Release

on:
  push:
    tags:
      - "v*"

permissions: {}

jobs:
  linux:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v7
        with:
          persist-credentials: false
          fetch-depth: 0          # tags and history, for the version and the changelog

      # arm64 is built under emulation on the amd64 runner.
      - uses: docker/setup-qemu-action@v4

      - uses: jdx/mise-action@v5   # provides crystal, and crystalreleaser if pinned in mise.toml

      - run: crystalreleaser build --split --clean

      - uses: actions/upload-artifact@v7
        with:
          name: dist-linux
          path: dist/

  darwin-arm64:
    runs-on: macos-26
    steps:
      - uses: actions/checkout@v7
        with:
          persist-credentials: false
          fetch-depth: 0
      - uses: jdx/mise-action@v5
      # Every formula of static_libs, the same on both architectures.
      - run: brew install openssl@4
      - run: crystalreleaser build --split --clean
      - uses: actions/upload-artifact@v7
        with:
          name: dist-darwin-arm64
          path: dist/

  darwin-amd64:
    runs-on: macos-26-intel
    steps:
      - uses: actions/checkout@v7
        with:
          persist-credentials: false
          fetch-depth: 0
      - uses: jdx/mise-action@v5
      # Every formula of static_libs, the same on both architectures.
      - run: brew install openssl@4
      - run: crystalreleaser build --split --clean
      - uses: actions/upload-artifact@v7
        with:
          name: dist-darwin-amd64
          path: dist/

  release:
    needs: [linux, darwin-arm64, darwin-amd64]
    runs-on: ubuntu-24.04
    permissions:
      contents: write             # create the release and upload its assets
    steps:
      - uses: actions/checkout@v7
        with:
          persist-credentials: false
          fetch-depth: 0

      - uses: jdx/mise-action@v5

      # Every runner's dist/<os>_<arch>/ lands side by side in dist/.
      - uses: actions/download-artifact@v8
        with:
          pattern: dist-*
          path: dist/
          merge-multiple: true

      - run: crystalreleaser release --merge
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          # Only needed with brews: / aqua: sections; they push to other
          # repositories, which the workflow token cannot write to.
          HOMEBREW_TAP_TOKEN: ${{ secrets.HOMEBREW_TAP_TOKEN }}
          AQUA_REGISTRY_TOKEN: ${{ secrets.AQUA_REGISTRY_TOKEN }}
```

Notes:

- `upload-artifact` does not keep Unix permissions; `release --merge` restores
  the executable bit of every binary it reads back.
- `fetch-depth: 0` matters: a release needs the previous tag and the history
  for its changelog, and refuses a shallow clone rather than publishing a
  changelog cut down to one commit.
- With the workflow above, a build job that fails stops everything: `needs:`
  skips the release job. To release what the other runners built all the
  same, let that job run anyway (`if: ${{ !cancelled() }}`) and call
  `release --merge --allow-missing`: the merge then warns about the missing
  platforms instead of failing with their list.
- The darwin jobs install every formula of `static_libs` (`brew install
  openssl@4`) before building: the runners do not all have the same OpenSSL
  by default (`openssl@3` on `macos-26-intel` when this was written), and a
  darwin build that still loads a Homebrew library fails its `otool -L`
  check rather than shipping a binary that only starts on that runner.
- GitHub retired the `macos-13` and `macos-14` images (macOS 14 on
  2026-11-02); `macos-26` is arm64 and `macos-26-intel` is x86_64.
