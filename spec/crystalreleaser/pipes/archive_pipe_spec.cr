require "compress/zip"
require "../../spec_helper"

private def archive(project : Fixture::Project, config : String? = nil, & : Crystalreleaser::Context ->) : Crystalreleaser::Context
  project.write(".crystalreleaser.yml", config) if config
  ctx = spec_context(project)
  yield ctx
  Crystalreleaser::Pipes::Archive.new.run(ctx)
  ctx
end

private def summary(entries) : Array({String, Int32, Char})
  entries.map { |entry| {entry.name, entry.mode, entry.type} }
end

describe Crystalreleaser::Pipes::Archive do
  it "packs each platform's binary with the default files into a tar.gz" do
    Fixture.project do |project|
      project.write("LICENSE", "MIT\n")
      project.write("README.md", "# toy\n")
      ctx = archive(project) do |context|
        fake_binary(context, "linux", "amd64")
        fake_binary(context, "darwin", "arm64")
      end

      archives = ctx.artifacts.filter(type: Crystalreleaser::Artifact::Type::Archive)
      archives.map { |artifact| {artifact.name, artifact.path, artifact.os, artifact.arch} }.should eq([
        {"toy_1.2.3-rc.1_linux_amd64.tar.gz", "dist/toy_1.2.3-rc.1_linux_amd64.tar.gz", "linux", "amd64"},
        {"toy_1.2.3-rc.1_darwin_arm64.tar.gz", "dist/toy_1.2.3-rc.1_darwin_arm64.tar.gz", "darwin", "arm64"},
      ])

      entries = read_tar_gz(project.path("dist/toy_1.2.3-rc.1_linux_amd64.tar.gz"))
      summary(entries).should eq([{"LICENSE", 0o644, '0'}, {"README.md", 0o644, '0'}, {"toy", 0o755, '0'}])
      String.new(entries.last.content).should eq("toy for linux/amd64")
    end
  end

  it "makes every member reproducible: root owner and the commit time" do
    Fixture.project do |project|
      ctx = archive(project) { |context| fake_binary(context, "linux", "amd64") }
      entry = read_tar_gz(project.path("dist/toy_1.2.3-rc.1_linux_amd64.tar.gz")).first

      {entry.uid, entry.gid, entry.uname, entry.gname, entry.mtime}
        .should eq({0, 0, "root", "root", Time.utc(2026, 11, 1, 12, 0, 0)})
      ctx.commit_time.should eq(Time.utc(2026, 11, 1, 12, 0, 0))
    end
  end

  it "produces identical bytes on a second run" do
    Fixture.project do |project|
      archive(project) { |context| fake_binary(context, "linux", "amd64") }
      first = File.read(project.path("dist/toy_1.2.3-rc.1_linux_amd64.tar.gz"))
      File.delete(project.path("dist/toy_1.2.3-rc.1_linux_amd64.tar.gz"))
      archive(project) { |context| fake_binary(context, "linux", "amd64") }

      File.read(project.path("dist/toy_1.2.3-rc.1_linux_amd64.tar.gz")).should eq(first)
    end
  end

  it "places globbed files under dst and wraps everything in a directory" do
    config = <<-YAML
      archives:
        - id: default
          wrap_in_directory: true
          files:
            - LICENSE
            - src: completions/*
              dst: completions
      YAML
    Fixture.project do |project|
      project.write("LICENSE", "MIT\n")
      project.write("completions/toy.bash", "complete\n")
      project.write("completions/toy.zsh", "#compdef\n")
      archive(project, config) { |context| fake_binary(context, "linux", "amd64") }

      summary(read_tar_gz(project.path("dist/toy_1.2.3-rc.1_linux_amd64.tar.gz"))).should eq([
        {"toy_1.2.3-rc.1_linux_amd64/", 0o755, '5'},
        {"toy_1.2.3-rc.1_linux_amd64/LICENSE", 0o644, '0'},
        {"toy_1.2.3-rc.1_linux_amd64/completions/", 0o755, '5'},
        {"toy_1.2.3-rc.1_linux_amd64/completions/toy.bash", 0o644, '0'},
        {"toy_1.2.3-rc.1_linux_amd64/completions/toy.zsh", 0o644, '0'},
        {"toy_1.2.3-rc.1_linux_amd64/toy", 0o755, '0'},
      ])
    end
  end

  it "keeps the executable bit of an extra file" do
    config = "archives:\n  - id: default\n    files: [scripts/*]\n"
    Fixture.project do |project|
      project.write("scripts/install.sh", "#!/bin/sh\n")
      File.chmod(project.path("scripts/install.sh"), 0o700)
      archive(project, config) { |context| fake_binary(context, "linux", "amd64") }

      summary(read_tar_gz(project.path("dist/toy_1.2.3-rc.1_linux_amd64.tar.gz"))).should eq([
        {"scripts/", 0o755, '5'}, {"scripts/install.sh", 0o755, '0'}, {"toy", 0o755, '0'},
      ])
    end
  end

  it "uses the zip format given by a format override" do
    config = <<-YAML
      archives:
        - id: default
          files: []
          format_overrides:
            - os: darwin
              formats: [zip]
      YAML
    Fixture.project do |project|
      archive(project, config) { |context| fake_binary(context, "darwin", "arm64") }

      path = project.path("dist/toy_1.2.3-rc.1_darwin_arm64.zip")
      Compress::Zip::File.open(path) do |zip|
        zip.entries.map(&.filename).should eq(["toy"])
        zip["toy"].open(&.gets_to_end).should eq("toy for darwin/arm64")
      end
    end
  end

  it "keeps the executable bit and the commit time in a zip, directories included" do
    config = "archives:\n  - id: default\n    formats: [zip]\n    wrap_in_directory: true\n    files: []\n"
    Fixture.project do |project|
      archive(project, config) { |context| fake_binary(context, "linux", "amd64") }
      path = project.path("dist/toy_1.2.3-rc.1_linux_amd64.zip")
      Compress::Zip::File.open(path) do |zip|
        zip.entries.map { |entry| {entry.filename, entry.time} }.should eq([
          {"toy_1.2.3-rc.1_linux_amd64/", Time.utc(2026, 11, 1, 12, 0, 0)},
          {"toy_1.2.3-rc.1_linux_amd64/toy", Time.utc(2026, 11, 1, 12, 0, 0)},
        ])
      end
      pending_tool!("unzip")
      run_tool(["unzip", "-q", path, "-d", project.path("out")])
      File.info(project.path("out/toy_1.2.3-rc.1_linux_amd64/toy")).permissions.value.should eq(0o755)
    end
  end

  it "never archives dist/, however the glob is written" do
    {"./*", "*", "."}.each do |glob|
      Fixture.project do |project|
        project.write("LICENSE", "MIT\n")
        project.write("dist/old.tar.gz", "previous output")
        archive(project, "archives:\n  - id: default\n    files: ['#{glob}']\n") { |context| fake_binary(context, "linux", "amd64") }
        names = read_tar_gz(project.path("dist/toy_1.2.3-rc.1_linux_amd64.tar.gz")).map(&.name)
        names.select(&.starts_with?("dist")).should be_empty
        names.should contain("LICENSE")
      end
    end
  end

  it "refuses a member that would be extracted outside the archive" do
    {"../../outside" => "../../outside/LICENSE", "/etc" => "/etc/LICENSE"}.each do |dst, member|
      Fixture.project do |project|
        project.write("LICENSE", "MIT\n")
        config = "archives:\n  - id: default\n    files:\n      - src: LICENSE\n        dst: #{dst}\n"
        expect_raises(Crystalreleaser::PackageError, "archives[0].files: #{member} would be extracted outside the archive") do
          archive(project, config) { |context| fake_binary(context, "linux", "amd64") }
        end
      end
    end
  end

  it "refuses a rendered name that is not a plain file name" do
    config = "archives:\n  - id: default\n    name_template: '{{ .ProjectName }}_{{ .Branch }}_{{ .Os }}_{{ .Arch }}'\n"
    Fixture.project do |project|
      expect_raises(Crystalreleaser::PackageError,
        %(archives[0].name_template: "toy_feature/x_linux_amd64.tar.gz" is not a plain file name)) do
        archive(project, config) do |context|
          context.branch = "feature/x"
          fake_binary(context, "linux", "amd64")
        end
      end
    end
  end

  # A directory entry means the directory, all of it: a glob would leave out
  # the hidden files and stop at a symbolic link to a directory.
  it "archives a directory with its hidden files and what its symbolic links point to" do
    Fixture.project do |project|
      project.write("docs/a.md", "a\n")
      project.write("docs/.dot", "dot\n")
      project.write("docs/.hidden/h", "h\n")
      project.write("real/inside.md", "inside\n")
      File.symlink("../real", project.path("docs/link"))
      archive(project, "archives:\n  - id: default\n    files:\n      - src: docs\n") { |context| fake_binary(context, "linux", "amd64") }

      summary(read_tar_gz(project.path("dist/toy_1.2.3-rc.1_linux_amd64.tar.gz"))).should eq([
        {"docs/", 0o755, '5'},
        {"docs/.dot", 0o644, '0'},
        {"docs/.hidden/", 0o755, '5'},
        {"docs/.hidden/h", 0o644, '0'},
        {"docs/a.md", 0o644, '0'},
        {"docs/link/", 0o755, '5'},
        {"docs/link/inside.md", 0o644, '0'},
        {"toy", 0o755, '0'},
      ])
    end
  end

  it "does not follow a symbolic link back into the directory it is in" do
    Fixture.project do |project|
      project.write("docs/a.md", "a\n")
      File.symlink("..", project.path("docs/loop"))
      expect_raises(Crystalreleaser::PackageError, "archives[0].files: docs/loop is a symbolic link to a directory that contains it") do
        archive(project, "archives:\n  - id: default\n    files:\n      - src: docs\n") { |context| fake_binary(context, "linux", "amd64") }
      end
    end
  end

  # The project path is not part of the pattern: its brackets and braces are
  # not glob syntax.
  it "resolves the globs in a project whose path holds glob characters" do
    Fixture.project do |outer|
      nested = Fixture::Project.new(outer.path("proj[1]{a}"))
      nested.write("shard.yml", File.read(outer.path("shard.yml")))
      nested.write("src/toy.cr", File.read(outer.path("src/toy.cr")))
      nested.write("LICENSE", "MIT\n")
      nested.write("docs/a.md", "a\n")
      archive(nested, "archives:\n  - id: default\n    files: [\"LICENSE*\", docs]\n") { |context| fake_binary(context, "linux", "amd64") }

      summary(read_tar_gz(nested.path("dist/toy_1.2.3-rc.1_linux_amd64.tar.gz"))).should eq([
        {"LICENSE", 0o644, '0'}, {"docs/", 0o755, '5'}, {"docs/a.md", 0o644, '0'}, {"toy", 0o755, '0'},
      ])
    end
  end

  # A pattern may match nothing (the default `CHANGELOG*` in a project without
  # one); a plain name that matches nothing is a typo.
  it "warns about a plain file name that matches nothing, not about a pattern" do
    Fixture.project do |project|
      project.write("LICENSE", "MIT\n")
      log = IO::Memory.new
      project.write(".crystalreleaser.yml", "archives:\n  - id: default\n    files: [LICENCE, \"CHANGELOG*\", LICENSE]\n")
      ctx = spec_context(project, log: log)
      fake_binary(ctx, "linux", "amd64")
      Crystalreleaser::Pipes::Archive.new.run(ctx)

      log.to_s.should eq("⚠ archives[0].files: LICENCE matches no file\n• toy_1.2.3-rc.1_linux_amd64.tar.gz\n")
    end
  end

  describe "the binary format" do
    config = "archives:\n  - id: default\n    formats: [binary]\n    name_template: \"{{ .ProjectName }}-{{ .Os }}-{{ .Arch }}\"\n"

    # The binary itself is the asset: no archive around it, no extension, and
    # none of the `files:`, which have nowhere to go.
    it "publishes the binary itself under the rendered name" do
      Fixture.project do |project|
        project.write("LICENSE", "MIT\n")
        ctx = archive(project, config) do |context|
          fake_binary(context, "linux", "amd64")
          fake_binary(context, "darwin", "arm64")
        end

        archives = ctx.artifacts.filter(type: Crystalreleaser::Artifact::Type::Archive)
        archives.map { |artifact| {artifact.name, artifact.path, artifact.os, artifact.arch, artifact.extra["format"]} }.should eq([
          {"toy-linux-amd64", "dist/toy-linux-amd64", "linux", "amd64", "binary"},
          {"toy-darwin-arm64", "dist/toy-darwin-arm64", "darwin", "arm64", "binary"},
        ])
        File.read(project.path("dist/toy-linux-amd64")).should eq("toy for linux/amd64")
        File.info(project.path("dist/toy-linux-amd64")).permissions.value.should eq(0o755)
        archives.first.size.should eq(19)
      end
    end

    it "can be published next to an archive of the same platform" do
      both = "archives:\n  - id: default\n    formats: [tar.gz, binary]\n"
      Fixture.project do |project|
        ctx = archive(project, both) { |context| fake_binary(context, "linux", "amd64") }
        ctx.artifacts.filter(type: Crystalreleaser::Artifact::Type::Archive).map(&.name)
          .should eq(["toy_1.2.3-rc.1_linux_amd64.tar.gz", "toy_1.2.3-rc.1_linux_amd64"])
      end
    end

    it "refuses two binaries for one platform: one file cannot be both" do
      Fixture.project do |project|
        expect_raises(Crystalreleaser::PackageError,
          "archives[0]: the binary format publishes one binary per platform, linux/amd64 has 2 (toy, toyctl): " \
          "give each build an archive of its own with builds:") do
          archive(project, config) do |context|
            fake_binary(context, "linux", "amd64")
            fake_binary(context, "linux", "amd64", "toy", "toyctl")
          end
        end
      end
    end

    # dist/<build>_<os>_<arch>/ is where the build left the binary.
    it "refuses a name that is already taken in dist/, such as the folder of the build" do
      taken = "archives:\n  - id: default\n    formats: [binary]\n    name_template: \"{{ .ProjectName }}_{{ .Os }}_{{ .Arch }}\"\n"
      Fixture.project do |project|
        expect_raises(Crystalreleaser::PackageError,
          "archives[0]: dist/toy_linux_amd64 already exists (the folder of a build?): change name_template") do
          archive(project, taken) { |context| fake_binary(context, "linux", "amd64") }
        end
      end
    end
  end

  it "leaves no file behind when an archive cannot be written" do
    {"tar.gz", "zip"}.each do |format|
      Fixture.project do |project|
        project.write(".crystalreleaser.yml", "archives:\n  - id: default\n    formats: [#{format}]\n")
        ctx = spec_context(project)
        fake_binary(ctx, "linux", "amd64")
        File.delete(ctx.dist_path("toy_linux_amd64", "toy"))
        expect_raises(File::NotFoundError) { Crystalreleaser::Pipes::Archive.new.run(ctx) }
        Dir.children(project.path("dist")).should eq(["toy_linux_amd64"])
      end
    end
  end

  it "names the broken symbolic link a glob matched" do
    Fixture.project do |project|
      File.symlink("nowhere", project.path("dangling"))
      expect_raises(Crystalreleaser::PackageError, "archives[0].files: dangling is a broken symbolic link") do
        archive(project, "archives:\n  - id: default\n    files: [dangling]\n") { |context| fake_binary(context, "linux", "amd64") }
      end
    end
  end

  it "takes a file once when two globs match it" do
    Fixture.project do |project|
      project.write("LICENSE.md", "MIT\n")
      archive(project, "archives:\n  - id: default\n    files: ['LICENSE*', '*.md']\n") { |context| fake_binary(context, "linux", "amd64") }
      read_tar_gz(project.path("dist/toy_1.2.3-rc.1_linux_amd64.tar.gz")).map(&.name).should eq(["LICENSE.md", "toy"])
    end
  end

  it "still refuses two different files under the same name" do
    config = "archives:\n  - id: default\n    files:\n      - src: a/NOTES\n        dst: doc\n      - src: b/NOTES\n        dst: doc\n"
    Fixture.project do |project|
      project.write("a/NOTES", "a")
      project.write("b/NOTES", "b")
      expect_raises(Crystalreleaser::PackageError, "archives[0]: doc/NOTES appears twice in toy_1.2.3-rc.1_linux_amd64.tar.gz") do
        archive(project, config) { |context| fake_binary(context, "linux", "amd64") }
      end
    end
  end

  it "only archives the builds it lists" do
    config = "archives:\n  - id: default\n    builds: [other]\n    files: []\n"
    Fixture.project(shard: Fixture::DEFAULT_SHARD + "\n  other:\n    main: src/other.cr\n") do |project|
      ctx = archive(project, config + "builds:\n  - id: toy\n    target: toy\n  - id: other\n    target: other\n") do |context|
        fake_binary(context, "linux", "amd64")
        fake_binary(context, "linux", "amd64", "other", "other")
      end

      ctx.artifacts.filter(type: Crystalreleaser::Artifact::Type::Archive).size.should eq(1)
      summary(read_tar_gz(project.path("dist/toy_1.2.3-rc.1_linux_amd64.tar.gz"))).should eq([{"other", 0o755, '0'}])
    end
  end

  # ustar: typeflag at 156, linkname at 157, size at 124, mode at 100 of the
  # header block, read from the bytes the archive holds.
  it "archives a symbolic link beside the binary for each alias, pointing at the binary" do
    Fixture.project do |project|
      archive(project) { |context| fake_binary(context, "linux", "amd64", aliases: ["toy-manager"]) }

      path = project.path("dist/toy_1.2.3-rc.1_linux_amd64.tar.gz")
      summary(read_tar_gz(path)).should eq([{"toy", 0o755, '0'}, {"toy-manager", 0o777, '2'}])
      header = tar_header(path, "toy-manager")
      header[156].chr.should eq('2')
      String.new(header[157, 3]).should eq("toy")
      header[160, 97].all?(&.zero?).should be_true
      String.new(header[124, 12]).should eq("00000000000\0")
      String.new(header[100, 8]).should eq("0000777\0")
    end
  end

  it "puts the symbolic link inside the wrap directory, next to the binary" do
    Fixture.project do |project|
      archive(project, "archives:\n  - id: default\n    wrap_in_directory: true\n    files: []\n") do |context|
        fake_binary(context, "linux", "amd64", aliases: ["toy-manager", "tm"])
      end

      path = project.path("dist/toy_1.2.3-rc.1_linux_amd64.tar.gz")
      summary(read_tar_gz(path)).should eq([
        {"toy_1.2.3-rc.1_linux_amd64/", 0o755, '5'},
        {"toy_1.2.3-rc.1_linux_amd64/tm", 0o777, '2'},
        {"toy_1.2.3-rc.1_linux_amd64/toy", 0o755, '0'},
        {"toy_1.2.3-rc.1_linux_amd64/toy-manager", 0o777, '2'},
      ])
      # The target is the sibling's name, not a path: it stays valid wherever
      # the archive is extracted.
      header = tar_header(path, "toy_1.2.3-rc.1_linux_amd64/toy-manager")
      header[156].chr.should eq('2')
      String.new(header[157, 3]).should eq("toy")
    end
  end

  it "is listed by the system tar as a link to the binary" do
    pending_tool!("tar")
    Fixture.project do |project|
      archive(project) { |context| fake_binary(context, "linux", "amd64", aliases: ["toy-manager"]) }
      output = IO::Memory.new
      Process.run("tar", ["-tvzf", project.path("dist/toy_1.2.3-rc.1_linux_amd64.tar.gz")], output: output).success?.should be_true
      lines = output.to_s.lines
      lines.last.should start_with("lrwxrwxrwx")
      lines.last.should end_with("toy-manager -> toy")
    end
  end

  it "records the aliases of the archive for the aqua pipe, and only when there are some" do
    Fixture.project do |project|
      ctx = archive(project) { |context| fake_binary(context, "linux", "amd64", aliases: ["toy-manager", "tm"]) }
      ctx.artifacts.filter(type: Crystalreleaser::Artifact::Type::Archive).first.extra["aliases"].should eq("toy-manager=toy,tm=toy")
    end
    Fixture.project do |project|
      ctx = archive(project) { |context| fake_binary(context, "linux", "amd64") }
      ctx.artifacts.filter(type: Crystalreleaser::Artifact::Type::Archive).first.extra.has_key?("aliases").should be_false
    end
  end

  it "refuses an alias that is also a file of the archive" do
    Fixture.project do |project|
      project.write("toy-manager", "a file\n")
      expect_raises(Crystalreleaser::PackageError, "archives[0]: toy-manager appears twice in toy_1.2.3-rc.1_linux_amd64.tar.gz") do
        archive(project, "archives:\n  - id: default\n    files: [toy-manager]\n") do |context|
          fake_binary(context, "linux", "amd64", aliases: ["toy-manager"])
        end
      end
    end
  end

  it "refuses two archives with the same name" do
    config = "archives:\n  - id: default\n    name_template: '{{ .ProjectName }}'\n"
    Fixture.project do |project|
      expect_raises(Crystalreleaser::PackageError, "archives[0]: two archives would be named toy.tar.gz; add .Os and .Arch to name_template") do
        archive(project, config) do |context|
          fake_binary(context, "linux", "amd64")
          fake_binary(context, "linux", "arm64")
        end
      end
    end
  end

  it "is skipped when nothing was built" do
    Fixture.project do |project|
      Crystalreleaser::Pipes::Archive.new.skip?(spec_context(project)).should eq("no binaries to archive")
    end
  end
end
