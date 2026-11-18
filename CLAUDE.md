# Project rules

## Run tasks through mise, never the raw command

`mise dev:spec`, not `crystal spec`. `mise dev:ameba`, not `ameba`.

The tasks carry the `depends` that generate what the compiler needs —
`licenses/` above all, which `src/crystalreleaser/licenses.cr` reads at macro
time — and the `timeout` bounds that keep a runaway process from burning hours.
On a bare checkout, a raw `crystal spec` fails at compile time with
"licenses/ is missing or empty": that is by design.

## Zero runtime dependencies

Only the stdlib, and no `development_dependencies` either: ameba is a mise
tool (`github:crystal-ameba/ameba`).
Formats the stdlib lacks (tar, ar, cpio, rpm) are written by hand under
`src/crystalreleaser/formats/`.

One step is left to a tool of the machine, and only when a config asks for
it: the OpenPGP signature of .rpm packages is made by `gpg`
(`src/crystalreleaser/gpg.cr`). The stdlib declares no private-key primitive
(nothing of `EVP_PKEY` or `RSA_*` in its `lib_crypto.cr`), and writing the
cryptography by hand was ruled out. The key and its passphrase never go
through an argument or the log: keep it so. `spec/fixtures/gpg/` holds keys
generated for the specs, never a real one.

## The canonical templates live outside this repository

`mise.toml`, `.github/workflows/ci.yml`, `Brewfile`,
`scripts/harvest-licenses.sh` and `scripts/kcov.css` are copies of
`~/.claude/templates/crystal/` (`mise.toml`, `ci-binary.yml`, `Brewfile`,
`harvest-licenses.sh`, `kcov.css`);
`src/crystalreleaser/version.cr` is adapted from `version.cr`. Fix the
canonical template first, then copy it back. The intentional divergences, and
there are only these:

- `mise.toml`
  - `APP_NAME = "crystalreleaser"`.
  - `dev:docs` writes to `docs/api/` instead of wiping `docs/`, which holds
    hand-written guides.
  - `dev:docker-image` removed, and `release:static` runs crystalreleaser
    itself instead of `docker buildx bake`: the tool releases itself
    (dogfooding), so there is no Dockerfile, Makefile.release nor
    docker-bake.hcl: the docker builds run in the image crystalreleaser
    generates (alpine:3.24 and Alpine's own Crystal, never a third-party
    Crystal image). It depends on `dev:build` and runs the two steps of
    release.yml (`build --split --snapshot --clean`, then `release --merge
    --snapshot --allow-missing --skip=publish`), so that the split and the
    merge are exercised on every push and not only by a tag.
  - `release:build` and `release:deps` removed: nothing calls them here, the
    release goes through `release:static` and release.yml.
  - `release:static` carries a `timeout`.
  - `DEFAULT_COMPILE_OPTS_RELEASE` and `COMPILE_OPTS_RELEASE` removed with
    `release:build`, their only user.
- `.github/workflows/ci.yml` — the header and the comment of
  `build_static_binaries` say that the release path is crystalreleaser
  itself, without the Makefile.release / docker-bake.hcl chain of the template.
  That job also runs the two binaries it built (`--version`). The macOS test
  jobs install `openssl@4`, and require it with `otool` and `cc` in
  `SPEC_REQUIRE_TOOLS`: the darwin libraries check is tried on a binary
  linked to it. A `test_cross`
  job runs the examples tagged `cross` with zig and an Alpine sysroot: the
  cross strategy is reached by nothing else. The linux and
  macOS test jobs set `SPEC_REQUIRE_TOOLS`, and the linux ones install `rpm`,
  `cpio`, `unzip` and `gnupg`: the specs check the formats written by hand
  with the system tools, sign .rpm packages with gpg, and a missing tool must
  fail rather than leave them pending.
- `.github/workflows/release.yml` has no canonical template: it is the
  split/merge release of docs/github-actions.md, building the tool from source.
- `Brewfile` — `gettext` removed, `cask 'docker'` uncommented with a comment
  of its own (the docker build strategy, not `docker buildx bake`), the
  commented `ollama` example dropped, `openssl@4` and `pkgconf` added: the release builds
  link OpenSSL 4 statically on macOS (`static_libs` in .crystalreleaser.yml).
- `version.cr` — VERSION reads the `CRYSTALRELEASER_VERSION` macro env first
  (ignored when empty), the shard version otherwise; TARGET knows `freebsd`,
  which the tool can target; the CLI wiring block is dropped.

## Licenses are not optional decoration

The static Linux binary embeds the notices listed in `licenses.manifest`
(`crystalreleaser licenses` prints them). `licenses/` is generated and
gitignored; `licenses.manifest`, `licenses-spdx/` (license texts shared by
SPDX id) and `licenses-upstream/` (the own license file of each library whose
license asks for its copyright notice: never the SPDX template, whose
copyright line is a blank) are tracked. The clib list
was checked against this binary's own static link line (see the manifest
header); re-check it whenever a stdlib module with a C library is added.

## Before claiming anything works

`mise dev:format-check`, `mise dev:ameba`, `mise dev:spec`, `mise dev:spec-mt`,
`mise dev:build` — with their output.
