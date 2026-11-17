# crystalreleaser

[![CI](https://github.com/jbox-web/crystalreleaser/actions/workflows/ci.yml/badge.svg)](https://github.com/jbox-web/crystalreleaser/actions/workflows/ci.yml)

Release automation for [Crystal](https://crystal-lang.org) projects, in the
spirit of [GoReleaser](https://goreleaser.com). From a git tag,
crystalreleaser:

1. builds the binaries of several platforms (natively, in docker, or by
   cross-compilation);
2. packs them into reproducible `.tar.gz` / `.zip` archives;
3. writes `checksums.txt` and a changelog from the commits since the last tag;
4. publishes a GitHub release with every asset;
5. produces `.deb` and `.rpm` packages, a Homebrew formula and an
   [aqua](https://aquaproj.github.io) registry entry.

It is a single executable with no runtime dependency, static on Linux and
linked only against the libraries macOS ships on macOS: tar, zip, ar,
cpio and the RPM format are written natively, without `nfpm`, `dpkg-deb` or
`rpmbuild`. Zip archives keep the Unix permissions, so an extracted binary is
still executable.

## Installation

From a release (Linux binaries are static), once one is published:

- the archives, `.deb` and `.rpm` of the GitHub release page;
- Homebrew: `brew install jbox-web/tap/crystalreleaser`;
- aqua, with the [jbox-web registry](https://github.com/jbox-web/aqua-registry)
  configured: package `jbox-web/crystalreleaser`.

From source (Crystal >= 1.20):

```sh
git clone https://github.com/jbox-web/crystalreleaser && cd crystalreleaser
mise dev:build          # bin/crystalreleaser
```

## Quickstart

```sh
crystalreleaser init                                 # .crystalreleaser.yml from shard.yml
crystalreleaser check                                # validate it
crystalreleaser release --snapshot --skip=publish    # try everything locally, in dist/
git tag v1.0.0 && git push --tags
GITHUB_TOKEN=... crystalreleaser release             # the real thing
```

Commands:

```
crystalreleaser init          generate a commented .crystalreleaser.yml from shard.yml
crystalreleaser check         load and validate the configuration, print the warnings
crystalreleaser build         [--snapshot] [--split] [--os X] [--arch Y] [--id ID] [--clean] [--parallelism N]
crystalreleaser release       [--snapshot] [--merge] [--allow-missing] [--skip=a,b] [--clean]
                              [--release-notes FILE] [--parallelism N]
crystalreleaser changelog     print the changelog the next release would carry
crystalreleaser licenses      print the third-party notices embedded in the binary
crystalreleaser --version
```

Global options: `-f/--config FILE` (default: `.crystalreleaser.yml`, then
`.crystalreleaser.yaml`, then `crystalreleaser.yml`), `--verbose` (debug lines,
backtraces on error), `--quiet` (warnings and errors only).

Outputs all go to `dist/`. It must be empty when a run starts: `--clean`
empties it. Add `/dist/` to `.gitignore`, since a release needs a clean tree.
Because `--clean` removes it, `dist` must be a directory inside the project:
the project itself, a parent or an absolute path is refused.

## Injecting the version

Crystal has no `-ldflags -X`. crystalreleaser exports each build's `env:`,
rendered, into the compiler's environment, and the code reads it at compile
time with the `env` macro:

```crystal
module MyApp
  VERSION = {{ env("MYAPP_VERSION") || "dev" }}
end
```

```yaml
builds:
  - id: myapp
    target: myapp
    env:
      - MYAPP_VERSION={{ .Version }}
      - MYAPP_COMMIT={{ .ShortCommit }}
```

crystalreleaser does this for itself with `CRYSTALRELEASER_VERSION`. With the
docker strategy the variables are passed to the container with `-e NAME`,
their values through the environment of the docker process: they do not
appear on its command line.

## The three build strategies

| Strategy | What runs | Platforms | Limits |
|---|---|---|---|
| `native` | `crystal build` on the host | the host's own os/arch | Skipped (with a warning) on any other host. `static: true` needs a musl host (Alpine): glibc cannot be linked statically, and macOS has no static linking at all. |
| `docker` | `crystal build` in a Crystal image, with `--static` when the platform says `static: true`: by default an image built on Alpine with Alpine's own Crystal (see below), or the project's Dockerfile, or a given image | linux/amd64, linux/arm64 | In an Alpine image, set `static: true`: a dynamic musl binary runs on no glibc distribution (`check` warns about it). Needs docker; the other architecture runs under QEMU and needs binfmt (`docker run --privileged --rm tonistiigi/binfmt --install arm64`). Emulated builds run one at a time. |
| `cross` | `crystal build --cross-compile`, then `zig cc` against a sysroot (or, with `linker: cc`, `cc --target` when `cc` is clang and `<triple>-gcc` when it is gcc) | any target with a sysroot | The sysroot must hold the target's static libraries (libgc, pcre2, libyaml, openssl...). crystalreleaser does not provide it; it fails if it is missing. |

A musl sysroot for linux/arm64 can be taken from Alpine (verified with zig
0.17.1, crystal 1.20.3, from a macOS arm64 host):

```sh
docker run --rm --platform linux/arm64 -v "$PWD/sysroot:/out" alpine:3 sh -c '
  apk add musl-dev gc-dev gc-static pcre2-dev pcre2-static yaml-static \
          zlib-static openssl-libs-static libevent-static &&
  cp -a /lib /out/lib && mkdir -p /out/usr && cp -a /usr/lib /out/usr/lib'
```

With zig, the sysroot is passed as `-L` folders only (zig would prefix even
absolute paths with `--sysroot`), and `-lunwind` is added for linux targets:
`zig cc` does not link the `libgcc_eh` gcc brings implicitly, which Crystal's
exceptions need.

The docker strategy runs as the calling user (dist/ is not left to root),
mounts the project at `/src`, and keeps the compiler cache and `lib/` in
named volumes: `crystalreleaser-cache-<arch>-<project>` and
`crystalreleaser-lib-<arch>-<project>-<build id>`, where `<project>` is a
digest of the project path. Two builds, or two projects built at the same
time, never share a `lib/`. Mounting that volume leaves an empty `lib/` in
the project when it had none.

The build image is one of three, set under `docker:`:

- by default, crystalreleaser builds it from a Dockerfile it writes: the
  stable Alpine (`alpine`, 3.24 by default), Alpine's own `crystal` package at
  the minor version of the host's compiler, the static libraries the stdlib
  links (boehm-gc, openssl, pcre2, libyaml, zlib, musl), and the project's own
  `packages` (`libxml2-static`, `gmp-static`...). Alpine's compiler and
  libraries, not a third-party image's;
- `dockerfile`: the project's own Dockerfile (its `target` stage, if given);
- `image`: an image pulled as it is.

A built image is built for each architecture with `docker build --platform
linux/<arch>`, once per build in a run, tagged
`crystalreleaser-build-<project>-<build id>-<arch>`. The build context is an
empty folder: the Dockerfile only installs the toolchain, the project is
mounted when the build runs.

After each build, `file` (when installed) checks the architecture and, when
asked, the static linking; a mismatch is a warning.

## Split / merge: building darwin and linux in one release

No machine builds everything: darwin needs a macOS runner. Split the release:

- on each runner, `crystalreleaser build --split` builds what that host can
  (or exactly `--os`/`--arch`) into `dist/<os>_<arch>/`, with a partial
  `artifacts.json`;
- a final job gathers the `dist/` folders and runs `crystalreleaser release
  --merge`: it checks that every configured platform is there, all from the
  same commit (`--allow-missing` turns a missing platform into a warning),
  then archives, checksums and publishes without compiling.

[docs/github-actions.md](docs/github-actions.md) has a complete workflow;
crystalreleaser's own [release workflow](.github/workflows/release.yml) uses
it.

## Pipeline

`validate → shard → git → before → build → archive → nfpm → checksum →
changelog → metadata → homebrew → aqua → release → homebrew (push) → aqua
(push)`

The formula and the registry entry are generated before the release is
published, so that what cannot be generated fails while nothing is public
yet; they are pushed once it is.

- `--skip=name,...` skips pipes by name; `publish` skips the GitHub release
  and the pushes of the formula and the registry entry (which are still
  generated in `dist/homebrew/` and `dist/aqua/`). `release` skips the GitHub
  release and, with it, those pushes: the files would point at assets that
  are not there. `validate`, `git`, `build`
  and `merge` cannot be skipped: a run means nothing without them.
- `--snapshot` releases an untagged, possibly dirty tree as
  `<next patch>-SNAPSHOT-<commit>` and never publishes.
- Without `--snapshot`, the tree must be clean and HEAD must carry exactly one
  semver tag. `GITHUB_TOKEN` (or `GH_TOKEN`), the tokens of the tap and of the
  registry, and `--release-notes` are checked before any build. In a split
  release they are only checked by `release --merge`, once every runner has
  built: `build --split` publishes nothing and asks for no token. A shallow
  clone is refused: the previous tag and the changelog need the history
  (`fetch-depth: 0` with actions/checkout). A snapshot on a shallow clone is
  built, with a warning when no tag is in reach: its version then starts
  from 0.0.0.
- The GitHub release is created as a draft and published once every asset is
  uploaded: a run that fails halfway leaves no public release with missing
  files, and running it again resumes that draft, skipping the assets already
  there with the same sha256. With `release.draft: true` it stays a draft,
  and the formula and the registry entry are written but not pushed, since
  their URLs only answer once the release is published.
- `dist/artifacts.json` lists the binaries, archives, packages and checksums
  with their sha256 (not the formula nor the registry entry, written after
  it); `dist/metadata.json` holds the release facts.

## Configuration

Every top-level key is optional, and so is nearly everything under them: an
entry that is written must give `platforms[].os` and `arch`,
`nfpms[].maintainer`, `aqua[].repository` and `aqua[].path`. Without a config
file, each target of `shard.yml` is built natively for the host and archived.

```yaml
version: 1
project_name: myapp                 # default: shard.yml name
dist: dist                          # a directory inside the project

env:                                # exported to builds and hooks, templated
  - FOO=bar

before:
  hooks:                            # shell commands, templated
    - shards install --production

builds:
  - id: myapp                       # default: target
    target: myapp                   # shard.yml target; main is deduced
    # main: src/myapp.cr            # or explicit
    binary: myapp                   # default: target
    flags: [--release, --no-debug]  # default: [--release]
    env:
      - MYAPP_VERSION={{ .Version }}
    platforms:                      # default: the host, native
      - { os: linux, arch: amd64, strategy: docker, static: true }
      - { os: linux, arch: arm64, strategy: docker, static: true }
      - { os: darwin, arch: arm64, strategy: native }
    docker:
      alpine: "3.24"                # the generated image (default): see below
      packages: [libxml2-static]    # apk packages the project links, besides the base ones
      # dockerfile: Dockerfile      # or the project's own Dockerfile...
      # target: toolchain           #   ...and its stage (default: the last one)
      # image: my/crystal:1.20      # or an image pulled as it is
      platform_flag: true           # pass --platform linux/<arch>
      shards_install: true
    cross:
      linker: zig                   # zig | cc
      sysroot: /opt/sysroots/{{ .Os }}-{{ .Arch }}
      link_flags: []

archives:
  - id: default
    builds: [myapp]                 # default: all
    formats: [tar.gz]               # tar.gz | zip | binary: see below
    format_overrides:
      - { os: windows, formats: [zip] }
    name_template: "{{ .ProjectName }}_{{ .Version }}_{{ .Os }}_{{ .Arch }}"
    wrap_in_directory: false
    files:                          # default: LICENSE*, README*, CHANGELOG*
      - LICENSE
      - src: completions/*
        dst: completions

checksum:
  name_template: checksums.txt
  algorithm: sha256
  split: false                      # true: one <asset>.sha256 per asset

changelog:
  use: git
  sort: asc                         # asc | desc
  filters:
    exclude: ["^docs:", "Merge pull request"]
  groups:
    - { title: Features, regexp: '^feat(\(.+\))?!?:' }
    - { title: Others }             # catch-all, last

release:
  github: { owner: me, name: myapp } # default: the origin remote
  draft: false
  prerelease: auto                  # auto: semver pre-release => prerelease
  replace_existing_artifacts: false
  make_latest: "true"               # true | false | legacy: see below
  name_template: "{{ .Tag }}"
  header: ""
  footer: ""

nfpms:
  - id: packages
    builds: [myapp]
    package_name: myapp
    formats: [deb, rpm]
    vendor: me
    homepage: https://example.com
    maintainer: Me <me@example.com> # required
    description: One line summary
    license: MIT
    section: utils                  # deb
    priority: optional              # deb
    bindir: /usr/bin
    contents:
      - { src: LICENSE, dst: /usr/share/doc/myapp/LICENSE }
      - { src: myapp.conf, dst: /etc/myapp/myapp.conf, type: config }  # see below
    dependencies: ["ca-certificates", "libfoo >= 1.2"]  # see below
    file_name_template: "{{ .PackageName }}_{{ .Version }}_{{ .Arch }}"

brews:
  - name: myapp
    repository: { owner: me, name: homebrew-tap, branch: master, token: "{{ .Env.HOMEBREW_TAP_TOKEN }}" }
    directory: Formula
    homepage: https://example.com
    description: One line summary
    license: MIT
    install: |                      # default: bin.install "<name>"
      bin.install "myapp"
    test: |                         # default: system bin/"<name>", "--version"
      system bin/"myapp", "--version"
    skip_upload: "false"            # false | true | auto: see below

aqua:
  - repository: { owner: me, name: aqua-registry, branch: master, token: "{{ .Env.AQUA_REGISTRY_TOKEN }}" }
    path: pkgs/me/myapp/registry.yaml
    description: One line summary
    skip_upload: "false"
```

`crystalreleaser check` validates all of it statically: unknown and repeated
keys, unique ids, references between sections, os/arch couples (linux/amd64,
linux/arm64, darwin/amd64, darwin/arm64, freebsd/amd64; windows is accepted
but not built yet), a static native build on a host that cannot link it,
`dist`, the install paths of packages (absolute, without `..`), regular
expressions, and the variables each template uses.

### Templates

`{{ .Name }}`, `{{ .Env.NAME }}`, and the filters `upper`, `lower`,
`replace "a" "b"`, `trimprefix "v"`, `trimsuffix "x"`, `shellquote`:
`{{ .Tag | trimprefix "v" | upper }}`. A quoted string is written as it is,
which is how a literal brace pair is obtained: `{{ "{{" }}.Id{{ "}}" }}`.

Values are inserted as they are. In a `before.hooks` command, which a shell
runs, pass anything that comes from git or from the environment through
`shellquote`: `echo {{ .Branch | shellquote }}`. Hooks are logged as written
in the config, never with the values they rendered.

| Variable | Value |
|---|---|
| `ProjectName` | project name |
| `Version` | tag without `v`: `1.2.3-rc.1` |
| `RawVersion` | `1.2.3` |
| `Tag`, `PreviousTag` | `v1.2.3-rc.1`, `v1.2.2` |
| `Major`, `Minor`, `Patch`, `Prerelease` | `1`, `2`, `3`, `rc.1` |
| `Commit`, `ShortCommit`, `Branch` | git HEAD |
| `Date`, `Timestamp` | run time, RFC 3339 UTC and Unix |
| `CrystalVersion` | the host's `crystal` version |
| `IsSnapshot` | `true` / `false` |
| `Os`, `Arch`, `Target`, `Binary` | per platform (builds, archives, packages) |
| `PackageName` | in `nfpms` |

An unknown variable, or one a field cannot provide, is an error naming the
field.

### Packages, formula, registry

- **dependencies**: one list for both formats, `name` or `name >= 1.2`
  (operators `<`, `<=`, `=`, `>=`, `>`; Debian's `name (>= 1.2)` is read too).
  Each format gets its own syntax: `name (>= 1.2)` in a .deb, with `<<` and
  `>>` for the strict comparisons.
- **.deb**: `debian-binary`, `control.tar.gz` (control with `Installed-Size`,
  md5sums), `data.tar.gz` with every parent directory listed.
- **.rpm**: lead, signature header (SHA1/SHA256 of the header, MD5 and size of
  header + payload), header with the payload SHA256 that rpm >= 4.14
  checks, gzip-compressed cpio payload. The package owns the directories only
  it creates (`/usr/share/doc/<name>`), so removing it removes them; system
  directories (`/usr/bin`) are left alone. No GPG signature: rpm 6 (Fedora 43
  and later) refuses unsigned packages unless installed with
  `rpm -i --nosignature`.
  A pre-release version `1.2.3-rc.1` becomes `1.2.3~rc.1` in both formats.
- **formats**, `binary`: the binary itself is the asset, with no archive
  around it and no extension, for the projects whose users download one
  file and run it. The `files:` are left out, and each platform must have
  one binary only. A name template without the version gives stable names:
  `name_template: "{{ .ProjectName }}-{{ .Os }}-{{ .Arch }}"` publishes
  `myapp-linux-amd64`. The Homebrew formula and the aqua entry only ever
  describe the tar.gz archives.
- **checksum**, `split`: one `<asset>.sha256` next to each asset, in the
  format of `sha256sum`, instead of the single `checksums.txt`; the aqua
  entry then points at `{{.Asset}}.sha256`.
- **make_latest**: `true` (default, and what GitHub does when told nothing)
  marks the release "Latest" when it is published, whatever its version: a
  `v1.9.1` published after `v2.0.0` takes the label. `legacy` lets GitHub
  pick by version, `false` never marks it. A pre-release is never "Latest".
- **contents**, `type`: without it a file is an ordinary one, replaced on
  every upgrade. `type: config` makes it a configuration file, which an
  upgrade does not silently overwrite once it was edited: dpkg asks (or keeps
  it), rpm saves the edited file as `.rpmsave`. `type: config|noreplace` is
  the same for dpkg; rpm then keeps the edited file and installs the new one
  as `.rpmnew`.
- **Homebrew**: `on_macos`/`on_linux` × `on_intel`/`on_arm` blocks pointing at
  the tar.gz assets of the release, written to pass `brew audit --strict`: no
  `version` line when Homebrew reads the version from the download URL (it
  is written only for a pre-release whose archive names do not hold the
  version), and `bin/"name"` in the default test.
- **aqua**: a `github_release` package whose `asset` template and
  `supported_envs` are derived from the archives actually produced.
- **skip_upload**, on a `brews` or an `aqua` entry: `false` (default) pushes
  the file on every release, `true` only writes it in `dist/`, and `auto`
  does not push it for a semver pre-release (`v1.2.0-rc.1`), so that the
  users of the tap or the registry only ever get stable versions.

### Third-party notices

The static binary embeds the licenses of what it links (openssl, pcre2,
libyaml, zlib, boehm-gc, musl, libgcc, Crystal): `crystalreleaser licenses`.
pcre2, libyaml, zlib and musl come with their own license file, copyright
notice included, as their licenses require.

## Development

```sh
mise dev:deps && mise dev:spec          # specs (no network)
mise dev:spec -- --tag docker           # only the docker-tagged examples
# only the cross-compilation examples: zig, and the sysroot built above
MISE_ZIG_VERSION=0.17.1 CRYSTALRELEASER_SYSROOT=$PWD/sysroot mise dev:spec -- --tag cross
CRYSTALRELEASER_SYSROOT=... mise dev:spec -- --tag cross
mise dev:ameba && mise dev:format-check
```

The specs check the hand-written formats with the system tools when they are
installed (`tar`, `cpio`, `unzip`, `dpkg-deb`, `rpm`) and are pending
otherwise. `SPEC_REQUIRE_TOOLS=rpm,dpkg-deb` (or `all`) makes a missing tool a
failure.

## License

MIT — see [LICENSE](LICENSE).
