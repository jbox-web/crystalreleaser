require "digest/sha256"
require "file_utils"

require "../context"
require "./builder"

lib LibC
  fun getgid : GidT
end

module Crystalreleaser
  module Builders
    # `crystal build --static` inside a Crystal Alpine image: the way to get
    # static musl binaries for linux/amd64 and linux/arm64 from any host with
    # docker. arm64 on an amd64 host (and the reverse) runs under QEMU
    # emulation, which binfmt must provide.
    #
    # The project is bind-mounted at /src and the container runs as the
    # calling user, so dist/ is not left owned by root. Named volumes keep
    # the compiler cache and lib/ between runs; they are chowned to that user
    # first, since docker creates them root-owned.
    #
    # The volumes are named after the architecture and the project (a digest
    # of its path), and the lib one after the build as well: two builds of a
    # run, or two projects built at once on the same machine, would otherwise
    # run `shards install` in the same lib/ at the same time.
    #
    # The values of `env:` reach the container through the environment of the
    # docker process (`-e NAME` without a value): on the command line they
    # would be readable in `ps` and in the --verbose log.
    #
    # The image is built, unless `docker.image` names one: from the
    # project's own `docker.dockerfile` (its `target` stage, if given), or
    # from the Dockerfile `generated_dockerfile` writes. It is built for the
    # platform once per build and architecture in a run, then used like any
    # other. The build context is an empty folder: the Dockerfile provides
    # the toolchain, and the project is mounted when the build runs.
    class Docker < Builder
      BINFMT_HINT = "docker run --privileged --rm tonistiigi/binfmt --install %s"
      # --production needs shard.lock, which a project without dependencies
      # may not have. Without one, `shards install` writes it in the project,
      # which is mounted: it is removed again, so that two builds do not leave
      # the tree dirty for the next release. Which of the two applies is
      # decided on the host, once: a container that looked for the file would
      # find the one another build is in the middle of writing.
      SHARDS_INSTALL_LOCKED   = "shards install --production"
      SHARDS_INSTALL_UNLOCKED = "shards install && rm -f shard.lock"

      @available : Bool? = nil

      def initialize(@host : Host)
        # Images already built in this run, and the lock that builds them
        # one at a time: the same image is then never built twice.
        @built = Set(String).new
        @image_lock = Mutex.new
      end

      def available? : Bool
        @available = Builders.capture(["docker", "info"])[0] if @available.nil?
        @available || false
      end

      # Emulated when the container's architecture is not the host's.
      def serial?(platform : Config::Platform, ctx : Context) : Bool
        emulated?(platform)
      end

      def emulated?(platform : Config::Platform) : Bool
        platform.arch != @host.arch
      end

      def cache_volume(platform : Config::Platform, ctx : Context) : String
        "crystalreleaser-cache-#{platform.arch}-#{project_key(ctx)}"
      end

      def lib_volume(build : Config::Build, platform : Config::Platform, ctx : Context) : String
        "crystalreleaser-lib-#{platform.arch}-#{project_key(ctx)}-#{build.id.gsub(/[^a-zA-Z0-9_.-]/, '_')}"
      end

      private def project_key(ctx : Context) : String
        Digest::SHA256.hexdigest(ctx.dir)[0, 12]
      end

      # What the docker process itself needs in its environment, for the
      # `-e NAME` of `command` to find a value.
      def environment(build : Config::Build, platform : Config::Platform, ctx : Context) : Hash(String, String)
        ctx.config_env(build, platform)
      end

      # What every generated image installs besides Crystal: what `shards`
      # and the version stamping need, and the static libraries the stdlib
      # links (boehm-gc, openssl, pcre2, libyaml, zlib, musl).
      BASE_PACKAGES = %w[
        shards git musl-dev gc-dev gc-static openssl-dev openssl-libs-static
        pcre2-dev pcre2-static yaml-dev yaml-static zlib-dev zlib-static
      ]

      def builds_image?(build : Config::Build) : Bool
        build.docker.image.nil?
      end

      def image(build : Config::Build, platform : Config::Platform, ctx : Context) : String
        image = build.docker.image
        return built_image(build, platform, ctx) unless image
        index = ctx.config.builds.index(build) || 0
        ctx.render(image, "builds[#{index}].docker.image", ctx.platform_vars(build, platform))
      end

      # The Dockerfile of the default image: the stable Alpine, its own
      # Crystal package at the minor version of the host's compiler (the
      # one mise pins), the base packages and the project's.
      def generated_dockerfile(build : Config::Build, ctx : Context) : String
        alpine = build.docker.alpine || Config::Docker::DEFAULT_ALPINE
        minor = ctx.crystal_version.split('.').first(2).join('.')
        raise BuildError.new("cannot tell the version of the host's crystal, which the image must match") if minor.empty?
        packages = ["crystal=~#{minor}"] + BASE_PACKAGES + build.docker.packages
        "# Written by crystalreleaser: the toolchain of the docker builds.\n" \
        "FROM alpine:#{alpine}\n" \
        "RUN apk add --no-cache #{packages.join(' ')}\n"
      end

      # The local tag of a built image, generated or from the project's
      # Dockerfile.
      def built_image(build : Config::Build, platform : Config::Platform, ctx : Context) : String
        "crystalreleaser-build-#{project_key(ctx)}-#{build.id.downcase.gsub(/[^a-z0-9_.-]/, '_')}-#{platform.arch}"
      end

      # `docker build` of the image for the platform: the project's
      # Dockerfile, or the generated one written in `context`, the build
      # context, empty otherwise.
      def image_command(build : Config::Build, platform : Config::Platform, ctx : Context, context : String) : Array(String)
        path =
          if dockerfile = build.docker.dockerfile
            File.join(ctx.dir, dockerfile).tap do |full|
              raise BuildError.new("#{label(build, platform)}: docker.dockerfile not found: #{dockerfile}") unless File.file?(full)
            end
          else
            File.join(context, "Dockerfile")
          end
        args = ["docker", "build", "--platform", "linux/#{platform.arch}", "-t", built_image(build, platform, ctx)]
        build.docker.target.try { |target| args.concat(["--target", target]) }
        args.concat(["-f", path, context])
      end

      private def build_image(build : Config::Build, platform : Config::Platform, ctx : Context) : Nil
        tag = built_image(build, platform, ctx)
        @image_lock.synchronize do
          next if @built.includes?(tag)
          context = File.join(Dir.tempdir, "crystalreleaser-context-#{Random::Secure.hex(6)}")
          Dir.mkdir_p(context)
          begin
            source = build.docker.dockerfile || "the generated Dockerfile"
            File.write(File.join(context, "Dockerfile"), generated_dockerfile(build, ctx)) unless build.docker.dockerfile
            args = image_command(build, platform, ctx, context)
            ctx.logger.debug(args.join(' '))
            ok, log = Builders.capture(args)
            raise BuildError.new("#{label(build, platform)}: building the image of #{source} failed: #{log.strip}") unless ok
          ensure
            FileUtils.rm_rf(context)
          end
          @built << tag
        end
      end

      def command(build : Config::Build, platform : Config::Platform, ctx : Context,
                  uid : UInt32 = LibC.getuid, gid : UInt32 = LibC.getgid) : Array(String)
        main = build.main || raise BuildError.new("#{label(build, platform)}: no main file")
        output = container_path(ctx, Builders.output_path(ctx, build, platform), build, platform)

        compile = ["crystal", "build", main, "-o", output] + build.flags
        compile << "--static" if platform.static?
        script = compile.join(' ') { |arg| Process.quote_posix(arg) }
        if build.docker.shards_install?
          install = File.exists?(File.join(ctx.dir, "shard.lock")) ? SHARDS_INSTALL_LOCKED : SHARDS_INSTALL_UNLOCKED
          script = "#{install} && #{script}"
        end

        args = ["docker", "run", "--rm"]
        args.concat(["--platform", "linux/#{platform.arch}"]) if build.docker.platform_flag?
        args.concat(["--user", "#{uid}:#{gid}",
                     "-v", "#{ctx.dir}:/src", "-w", "/src",
                     "-v", "#{cache_volume(platform, ctx)}:/cache",
                     "-v", "#{lib_volume(build, platform, ctx)}:/src/lib",
                     "-e", "HOME=/cache/home", "-e", "CRYSTAL_CACHE_DIR=/cache/crystal"])
        environment(build, platform, ctx).each_key { |name| args.concat(["-e", name]) }
        # Crystal images set `crystal` as their entrypoint.
        args.concat(["--entrypoint", "sh", image(build, platform, ctx), "-c", script])
      end

      # Run as root once, so the volumes belong to the user the build runs as.
      def prepare_command(build : Config::Build, platform : Config::Platform, ctx : Context,
                          uid : UInt32 = LibC.getuid, gid : UInt32 = LibC.getgid) : Array(String)
        args = ["docker", "run", "--rm"]
        args.concat(["--platform", "linux/#{platform.arch}"]) if build.docker.platform_flag?
        args.concat(["-v", "#{cache_volume(platform, ctx)}:/cache", "-v", "#{lib_volume(build, platform, ctx)}:/lib-cache",
                     "--entrypoint", "chown", image(build, platform, ctx), "-R", "#{uid}:#{gid}", "/cache", "/lib-cache"])
      end

      def build(build : Config::Build, platform : Config::Platform, ctx : Context) : Path
        raise BuildError.new("#{label(build, platform)}: docker is not available (`docker info` failed)") unless available?
        check_emulation(build, platform) if emulated?(platform)
        output = Builders.output_path(ctx, build, platform)
        Dir.mkdir_p(File.dirname(output))
        build_image(build, platform, ctx) if builds_image?(build)

        {prepare_command(build, platform, ctx), command(build, platform, ctx)}.each do |args|
          ctx.logger.debug(args.join(' '))
          ok, log = Builders.capture(args, env: environment(build, platform, ctx))
          raise BuildError.new("#{label(build, platform)}: #{log.strip}") unless ok
        end
        Path[output]
      end

      # Emulation needs binfmt handlers; buildx lists the platforms they
      # cover.
      private def check_emulation(build : Config::Build, platform : Config::Platform) : Nil
        ok, output = Builders.capture(["docker", "buildx", "ls"])
        return if ok && output.includes?("linux/#{platform.arch}")
        raise BuildError.new("#{label(build, platform)}: docker cannot run linux/#{platform.arch} images on this " \
                             "#{@host} host; install the QEMU handlers with: #{BINFMT_HINT % platform.arch}")
      end

      private def container_path(ctx : Context, path : String, build : Config::Build, platform : Config::Platform) : String
        relative = Path[path].relative_to(ctx.dir).to_s
        if relative.starts_with?("..")
          raise BuildError.new("#{label(build, platform)}: dist must be inside the project to build with docker")
        end
        "/src/#{relative}"
      end
    end
  end
end
