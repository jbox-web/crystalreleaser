# Builds a Context for a fixture project, with git facts filled in as the git
# pipe would, so unit specs can render templates and build commands without
# running the pipeline.
def spec_context(project : Fixture::Project,
                 host = Crystalreleaser::Host.new("linux", "amd64", musl: false),
                 options = Crystalreleaser::Options.new,
                 env = {} of String => String,
                 log : IO = IO::Memory.new) : Crystalreleaser::Context
  config = Crystalreleaser::Config.load(project.dir, nil, host)
  ctx = Crystalreleaser::Context.new(project.dir, config, host, options,
    Crystalreleaser::Logger.new(log, color: false), env: env, now: Time.utc(2026, 11, 12, 8, 30, 0))
  ctx.version_info = Crystalreleaser::VersionInfo.release("v1.2.3-rc.1")
  ctx.previous_tag = "v1.2.2"
  ctx.commit = "0123456789abcdef0123456789abcdef01234567"
  ctx.short_commit = "0123456"
  ctx.branch = "master"
  ctx.commit_time = Time.utc(2026, 11, 1, 12, 0, 0)
  ctx.crystal_version = "1.20.3"
  ctx
end
