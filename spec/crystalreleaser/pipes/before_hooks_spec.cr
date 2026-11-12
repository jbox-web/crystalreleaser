require "../../spec_helper"

describe Crystalreleaser::Pipes::BeforeHooks do
  it "is skipped without hooks" do
    Fixture.project do |project|
      Crystalreleaser::Pipes::BeforeHooks.new.skip?(spec_context(project)).should eq("no hooks configured")
    end
  end

  it "runs each templated hook in the project with the configured env" do
    config = <<-YAML
      env:
        - GREETING=hello
      before:
        hooks:
          - sh -c 'echo "$GREETING {{ .ProjectName }} {{ .Version }}" > hook.txt'
      YAML
    Fixture.project(config: config) do |project|
      Crystalreleaser::Pipes::BeforeHooks.new.run(spec_context(project, env: ENV.to_h))
      File.read(project.path("hook.txt")).should eq("hello toy 1.2.3-rc.1\n")
    end
  end

  it "cannot be hijacked by a branch name once the value is shell-quoted" do
    config = "before:\n  hooks:\n    - echo {{ .Branch | shellquote }} > out.txt\n"
    Fixture.project(config: config) do |project|
      ctx = spec_context(project, env: ENV.to_h)
      ctx.branch = "x;touch PWNED"
      Crystalreleaser::Pipes::BeforeHooks.new.run(ctx)
      File.exists?(project.path("PWNED")).should be_false
      File.read(project.path("out.txt")).should eq("x;touch PWNED\n")
    end
  end

  it "logs and reports the hook as written, never the values it rendered" do
    config = "before:\n  hooks:\n    - \"test {{ .Env.HOOK_SECRET }} = nope\"\n"
    Fixture.project(config: config) do |project|
      log = IO::Memory.new
      ctx = spec_context(project, env: ENV.to_h.merge({"HOOK_SECRET" => "s3cr3t-value"}), log: log)
      error = expect_raises(Crystalreleaser::HookError) { Crystalreleaser::Pipes::BeforeHooks.new.run(ctx) }
      error.message.should eq("before hook failed (exit 1): test {{ .Env.HOOK_SECRET }} = nope\n")
      log.to_s.should eq("• test {{ .Env.HOOK_SECRET }} = nope\n")
    end
  end

  it "fails with the command and its output" do
    config = <<-YAML
      before:
        hooks:
          - sh -c 'echo broken >&2; exit 3'
      YAML
    Fixture.project(config: config) do |project|
      expect_raises(Crystalreleaser::Error, "before hook failed (exit 3): sh -c 'echo broken >&2; exit 3'\nbroken") do
        Crystalreleaser::Pipes::BeforeHooks.new.run(spec_context(project, env: ENV.to_h))
      end
    end
  end

  # Same byte count as in builder_spec: `seq 1 200000` prints 1 288 895 bytes.
  it "keeps the whole output of a hook that floods stdout and stderr at once" do
    config = "before:\n  hooks:\n    - \"seq 1 200000 & seq 1 200000 >&2; wait; exit 4\"\n"
    Fixture.project(config: config) do |project|
      ctx = spec_context(project, env: ENV.to_h)
      done = Channel(String?).new(1)
      spawn do
        Crystalreleaser::Pipes::BeforeHooks.new.run(ctx)
        done.send(nil)
      rescue error : Crystalreleaser::HookError
        done.send(error.message)
      end
      select
      when message = done.receive
        message = message.should_not be_nil
        header = "before hook failed (exit 4): seq 1 200000 & seq 1 200000 >&2; wait; exit 4\n"
        message.should start_with(header)
        # The output is stripped: its last newline is gone.
        message.bytesize.should eq(header.bytesize + 2_577_790 - 1)
      when timeout(60.seconds)
        fail "the hook was still being read after 60 seconds"
      end
    end
  end

  it "reports a hook killed by a signal as a hook error" do
    config = "before:\n  hooks:\n    - \"echo dying; kill -9 $$\"\n"
    Fixture.project(config: config) do |project|
      expect_raises(Crystalreleaser::HookError, "before hook failed (killed by signal KILL): echo dying; kill -9 $$\ndying") do
        Crystalreleaser::Pipes::BeforeHooks.new.run(spec_context(project, env: ENV.to_h))
      end
    end
  end

  it "logs each line of the hook output under --verbose" do
    config = "before:\n  hooks:\n    - \"echo one; echo two >&2\"\n"
    Fixture.project(config: config) do |project|
      log = IO::Memory.new
      host = Crystalreleaser::Host.new("linux", "amd64", musl: false)
      ctx = Crystalreleaser::Context.new(project.dir, Crystalreleaser::Config.load(project.dir, nil, host), host,
        Crystalreleaser::Options.new, Crystalreleaser::Logger.new(log, Crystalreleaser::Logger::Level::Debug, color: false),
        env: ENV.to_h)
      Crystalreleaser::Pipes::BeforeHooks.new.run(ctx)
      log.to_s.should eq("• echo one; echo two >&2\n  one\n  two\n")
    end
  end
end
