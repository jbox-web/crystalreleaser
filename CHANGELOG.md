# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.0] - 2026-11-18

### Changed

- **Breaking:** `static_libs` is a list, one entry per Homebrew formula, so
  that a build can link the libraries of several formulas statically
  (`openssl@4` and `libssh2`). The single mapping of 0.2.x is refused with
  the line to write instead: turn `formula:` and `libs:` into the first
  entry of the list (`- formula: openssl@4`). The `lib/pkgconfig` of every
  formula comes first in `PKG_CONFIG_PATH`, in the order they are written,
  and `check` refuses a formula written twice, and a library written twice
  or taken from two formulas.

### Fixed

- The libgcc notice of `crystalreleaser licenses` names the license the GCC
  Runtime Library Exception 3.1 applies to, GPL-3.0-or-later, instead of
  GPL-2.0/LGPL-2.1

## [0.2.1] - 2026-11-17

### Fixed

- `static_libs` puts the formula's `lib/pkgconfig` first in
  `PKG_CONFIG_PATH` for the build: Crystal declares the OpenSSL API of the
  version pkg-config reports, which was the OpenSSL Homebrew had linked
  (openssl@3 on macos-26-intel) rather than the formula whose archives are
  linked.

## [0.2.0] - 2026-11-17

### Added

- `static_libs` on a build: the native darwin builds link the listed
  libraries of a Homebrew formula statically (`formula: openssl@4`,
  `libs: [ssl, crypto]`), and stop before compiling when the formula or an
  archive is missing.
- Every darwin build checks the libraries its binary loads with `otool -L`
  and fails when one is outside `/usr/lib` and `/System/Library`.

### Changed

- crystalreleaser's own darwin binaries link OpenSSL 4 through
  `static_libs`; `scripts/static-libs.sh` and `scripts/check-darwin-linkage.sh`
  are gone.

### Fixed

- The aqua registry entry is written the way aqua registries write theirs,
  list indented under `packages:`: a registry that concatenates the entries
  of its packages took the old one for invalid YAML.

## [0.1.0] - 2026-11-17

### Added

- `init`, `check`, `build`, `release`, `changelog` and `licenses` commands.
- `.crystalreleaser.yml` configuration, defaults derived from `shard.yml`,
  static validation of every key and template.
- Builds: native, docker (static musl, amd64 and arm64) and cross (zig or cc
  with a sysroot), run in parallel.
- Split builds (`build --split`) and their merge (`release --merge`) to
  release darwin and linux binaries from several runners.
- Reproducible tar.gz and zip archives, both written natively; zip entries
  keep their Unix permissions.
- `checksums.txt`, changelog from git, `artifacts.json` and `metadata.json`.
- GitHub release: created as a draft and published once every asset is
  uploaded, resumed by a rerun, with retries and rate-limit handling.
- Native `.deb` and `.rpm` packages, with versioned dependencies written in
  each format's own syntax.
- Homebrew formula and aqua registry entry, written to `dist/` and pushed to
  their repositories; `skip_upload` keeps pre-releases out of them.
- Docker builds in an image built on the stable Alpine with Alpine's own
  Crystal (`docker.alpine`, `docker.packages`), in the project's own
  Dockerfile (`docker.dockerfile`, `docker.target`), or in a given image.
- `binary` archive format, the binary itself under a name of its own, and
  `checksum.split`, one `<asset>.sha256` per asset.
- `release.make_latest`; the release is pinned to the built commit.
- Configuration files in packages (`contents[].type: config` and
  `config|noreplace`).
- Formula and registry entry generated before the release is published and
  pushed after it; formulae that pass `brew audit --strict`.
- darwin binaries that link OpenSSL statically and only depend on libraries
  macOS ships.
- `.crystalreleaser.example.yml`, a complete commented configuration.
