require "../../spec_helper"

private API     = "https://api.github.com/repos/jbox-web/toy"
private UPLOADS = "https://uploads.github.com/repos/jbox-web/toy"

private CONFIG = <<-YAML
  release:
    github:
      owner: jbox-web
      name: toy
    header: "Release {{ .Tag }}"
    footer: "Enjoy."
  YAML

private def release_context(project : Fixture::Project, transport : FakeTransport) : Crystalreleaser::Context
  options = Crystalreleaser::Options.new
  options.publish = true
  ctx = spec_context(project, options: options, env: {"GITHUB_TOKEN" => "secret"})
  ctx.github_client_factory = ->(_token : String) { fake_client(transport).as(Crystalreleaser::Github::Client) }
  ctx.changelog = "## Changelog\n\n* abc feat: x\n"
  {"toy_1.2.3-rc.1_linux_amd64.tar.gz", "checksums.txt"}.each do |name|
    path = ctx.dist_path(name)
    Dir.mkdir_p(File.dirname(path))
    File.write(path, name)
    type = name.ends_with?(".tar.gz") ? Crystalreleaser::Artifact::Type::Archive : Crystalreleaser::Artifact::Type::Checksum
    ctx.artifacts.add(Crystalreleaser::Artifact.new(type, name, ctx.relative(path)))
  end
  ctx
end

private TAG      = "#{API}/releases/tags/v1.2.3-rc.1"
private RELEASES = "#{API}/releases?per_page=100&page=1"
private ASSETS   = "#{API}/releases/7/assets?per_page=100&page=1"
private ARCHIVE  = "POST #{UPLOADS}/releases/7/assets?name=toy_1.2.3-rc.1_linux_amd64.tar.gz"
private CHECKSUM = "POST #{UPLOADS}/releases/7/assets?name=checksums.txt"

# sha256 of the text "checksums.txt", the content release_context gives that file.
private CHECKSUM_DIGEST = "sha256:092ed35ce184329ae3ccf786a43135951d8af11dc3a9bd313435f757626b3527"

describe Crystalreleaser::Pipes::Release do
  it "creates a draft, uploads archives and checksums, then publishes" do
    Fixture.project(config: CONFIG) do |project|
      transport = FakeTransport.new do |request|
        case {request.method, request.url}
        when {"GET", TAG}                then github_response(404)
        when {"GET", RELEASES}           then github_response(200, "[]")
        when {"POST", "#{API}/releases"} then github_response(201, %({"id": 7, "draft": true}))
        when {"GET", ASSETS}             then github_response(200, "[]")
        else                                  github_response(201, "{}")
        end
      end
      Crystalreleaser::Pipes::Release.new.run(release_context(project, transport))

      transport.calls.should eq([
        "GET #{TAG}",
        "GET #{RELEASES}",
        "POST #{API}/releases",
        "GET #{ASSETS}",
        ARCHIVE,
        CHECKSUM,
        "PATCH #{API}/releases/7",
      ])
      JSON.parse(transport.requests[2].body).should eq(JSON.parse(<<-'JSON'))
        {"tag_name": "v1.2.3-rc.1", "target_commitish": "0123456789abcdef0123456789abcdef01234567",
         "name": "v1.2.3-rc.1", "draft": true, "prerelease": true,
         "body": "Release v1.2.3-rc.1\n\n## Changelog\n\n* abc feat: x\n\nEnjoy.\n"}
        JSON
      transport.requests[4].body.should eq("toy_1.2.3-rc.1_linux_amd64.tar.gz")
      JSON.parse(transport.requests[6].body).should eq(JSON.parse(%({"draft": false, "make_latest": "true"})))
    end
  end

  # Without it, nobody can verify the signed packages of the release.
  it "uploads the public key the packages were signed with" do
    Fixture.project(config: CONFIG) do |project|
      transport = FakeTransport.new do |request|
        case {request.method, request.url}
        when {"GET", TAG}                then github_response(404)
        when {"GET", RELEASES}           then github_response(200, "[]")
        when {"POST", "#{API}/releases"} then github_response(201, %({"id": 7, "draft": true}))
        when {"GET", ASSETS}             then github_response(200, "[]")
        else                                  github_response(201, "{}")
        end
      end
      ctx = release_context(project, transport)
      path = ctx.dist_path("RPM-GPG-KEY-toy")
      File.write(path, "the public key")
      ctx.artifacts.add(Crystalreleaser::Artifact.new(Crystalreleaser::Artifact::Type::PublicKey, "RPM-GPG-KEY-toy", ctx.relative(path)))
      Crystalreleaser::Pipes::Release.new.run(ctx)

      transport.calls.should contain("POST #{UPLOADS}/releases/7/assets?name=RPM-GPG-KEY-toy")
      transport.requests.find!(&.url.ends_with?("name=RPM-GPG-KEY-toy")).body.should eq("the public key")
    end
  end

  # GitHub does not keep a make_latest given when the draft is created
  # (observed on a real repository): it only counts on the request that
  # publishes. Without it, a v1.9.1 published after v2.0.0 becomes "Latest".
  {"legacy", "false"}.each do |value|
    it "publishes with make_latest: #{value} when the config says so" do
      Fixture.project(config: CONFIG.sub("release:\n", "release:\n  make_latest: #{value}\n")) do |project|
        transport = FakeTransport.new do |request|
          case {request.method, request.url}
          when {"GET", TAG}                then github_response(404)
          when {"GET", RELEASES}           then github_response(200, "[]")
          when {"POST", "#{API}/releases"} then github_response(201, %({"id": 7, "draft": true}))
          when {"GET", ASSETS}             then github_response(200, "[]")
          else                                  github_response(201, "{}")
          end
        end
        Crystalreleaser::Pipes::Release.new.run(release_context(project, transport))

        JSON.parse(transport.requests.last.body).should eq(JSON.parse(%({"draft": false, "make_latest": "#{value}"})))
        JSON.parse(transport.requests[2].body)["make_latest"]?.should be_nil
      end
    end
  end

  it "leaves the release a draft when an upload fails" do
    Fixture.project(config: CONFIG) do |project|
      transport = FakeTransport.new do |request|
        case {request.method, request.url}
        when {"GET", TAG}                then github_response(404)
        when {"GET", RELEASES}           then github_response(200, "[]")
        when {"POST", "#{API}/releases"} then github_response(201, %({"id": 7, "draft": true}))
        when {"GET", ASSETS}             then github_response(200, "[]")
        else                                  github_response(500, %({"message": "boom"}))
        end
      end
      expect_raises(Crystalreleaser::GithubError, "HTTP 500: boom") do
        Crystalreleaser::Pipes::Release.new.run(release_context(project, transport))
      end
      transport.calls.should_not contain("PATCH #{API}/releases/7")
    end
  end

  it "resumes the draft a failed run left, then publishes it" do
    Fixture.project(config: CONFIG) do |project|
      transport = FakeTransport.new do |request|
        case {request.method, request.url}
        when {"GET", TAG} then github_response(404)
        when {"GET", RELEASES}
          github_response(200, %([{"id": 3, "tag_name": "v1.2.2", "draft": true}, {"id": 7, "tag_name": "v1.2.3-rc.1", "draft": true}]))
        when {"GET", ASSETS} then github_response(200, "[]")
        else                      github_response(200, "{}")
        end
      end
      Crystalreleaser::Pipes::Release.new.run(release_context(project, transport))

      transport.calls.should eq([
        "GET #{TAG}", "GET #{RELEASES}", "PATCH #{API}/releases/7", "GET #{ASSETS}", ARCHIVE, CHECKSUM,
        "PATCH #{API}/releases/7",
      ])
      JSON.parse(transport.requests[2].body)["draft"].should be_true
      JSON.parse(transport.requests[6].body).should eq(JSON.parse(%({"draft": false, "make_latest": "true"})))
    end
  end

  it "keeps the release a draft with release.draft: true" do
    Fixture.project(config: CONFIG + "\n  draft: true\n") do |project|
      transport = FakeTransport.new do |request|
        case {request.method, request.url}
        when {"GET", TAG}                then github_response(404)
        when {"GET", RELEASES}           then github_response(200, "[]")
        when {"POST", "#{API}/releases"} then github_response(201, %({"id": 7, "draft": true}))
        when {"GET", ASSETS}             then github_response(200, "[]")
        else                                  github_response(201, "{}")
        end
      end
      Crystalreleaser::Pipes::Release.new.run(release_context(project, transport))
      transport.calls.should eq(["GET #{TAG}", "GET #{RELEASES}", "POST #{API}/releases", "GET #{ASSETS}", ARCHIVE, CHECKSUM])
    end
  end

  it "updates a published release without unpublishing it, and replaces assets of the same name" do
    Fixture.project(config: CONFIG + "\n  replace_existing_artifacts: true\n  prerelease: \"false\"\n") do |project|
      transport = FakeTransport.new do |request|
        case {request.method, request.url}
        when {"GET", TAG} then github_response(200, %({"id": 7, "draft": false}))
        when {"GET", ASSETS}
          github_response(200, %([{"id": 31, "name": "checksums.txt", "state": "uploaded", "digest": "sha256:0000"}]))
        else github_response(200, "{}")
        end
      end
      Crystalreleaser::Pipes::Release.new.run(release_context(project, transport))

      transport.calls.should eq([
        "GET #{TAG}",
        "PATCH #{API}/releases/7",
        "GET #{ASSETS}",
        ARCHIVE,
        "DELETE #{API}/releases/assets/31",
        CHECKSUM,
      ])
      body = JSON.parse(transport.requests[1].body)
      body["prerelease"].should be_false
      body["draft"].should be_false
    end
  end

  it "skips an asset already uploaded with the same content, so a failed run can be rerun" do
    Fixture.project(config: CONFIG) do |project|
      transport = FakeTransport.new do |request|
        case {request.method, request.url}
        when {"GET", TAG} then github_response(200, %({"id": 7, "draft": true}))
        when {"GET", ASSETS}
          github_response(200, %([{"id": 31, "name": "checksums.txt", "state": "uploaded", "digest": "#{CHECKSUM_DIGEST}"}]))
        else github_response(200, "{}")
        end
      end
      Crystalreleaser::Pipes::Release.new.run(release_context(project, transport))
      transport.calls.should eq(["GET #{TAG}", "PATCH #{API}/releases/7", "GET #{ASSETS}", ARCHIVE, "PATCH #{API}/releases/7"])
    end
  end

  it "replaces the empty asset a failed upload left, whatever replace_existing_artifacts says" do
    Fixture.project(config: CONFIG) do |project|
      transport = FakeTransport.new do |request|
        case {request.method, request.url}
        when {"GET", TAG} then github_response(200, %({"id": 7, "draft": false}))
        when {"GET", ASSETS}
          github_response(200, %([{"id": 31, "name": "checksums.txt", "state": "starter", "digest": null}]))
        else github_response(200, "{}")
        end
      end
      Crystalreleaser::Pipes::Release.new.run(release_context(project, transport))
      transport.calls.should eq(["GET #{TAG}", "PATCH #{API}/releases/7", "GET #{ASSETS}", ARCHIVE,
                                 "DELETE #{API}/releases/assets/31", CHECKSUM])
    end
  end

  it "refuses to overwrite an asset with another content unless replace_existing_artifacts is set" do
    Fixture.project(config: CONFIG) do |project|
      transport = FakeTransport.new do |request|
        if request.url.ends_with?("/assets?per_page=100&page=1")
          github_response(200, %([{"id": 31, "name": "checksums.txt", "state": "uploaded", "digest": "sha256:0000"}]))
        else
          github_response(200, %({"id": 7}))
        end
      end
      expect_raises(Crystalreleaser::GithubError,
        "asset checksums.txt already exists on release v1.2.3-rc.1; set release.replace_existing_artifacts: true to replace it") do
        Crystalreleaser::Pipes::Release.new.run(release_context(project, transport))
      end
    end
  end

  it "derives the repository from the origin remote" do
    Fixture.project do |project|
      project.init_git
      project.git("remote", "add", "origin", "git@github.com:jbox-web/toy.git")
      ctx = spec_context(project)
      ctx.release_repo.should eq({"jbox-web", "toy"})
      project.git("remote", "set-url", "origin", "https://github.com/jbox-web/other")
      ctx.release_repo.should eq({"jbox-web", "other"})
    end
  end

  it "fails clearly when no repository can be found" do
    Fixture.project do |project|
      project.init_git
      expect_raises(Crystalreleaser::ConfigError, "release.github is not set and the origin remote is not a GitHub repository") do
        spec_context(project).release_repo
      end
    end
  end
end
