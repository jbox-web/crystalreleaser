# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
