require "../context"
require "../pipe"
require "../subprocess"

module Crystalreleaser
  module Pipes
    # `before.hooks`: shell commands run in the project directory, templated,
    # with the global `env:` exported. Skipped with --skip=before.
    #
    # The log and the error show the hook as written in the config, not the
    # rendered command: a hook may well render a token from `.Env`.
    class BeforeHooks < Pipe
      def name : String
        "before"
      end

      def description : String
        "running before hooks"
      end

      def skip?(ctx : Context) : String?
        "no hooks configured" if ctx.config.before.hooks.empty?
      end

      def run(ctx : Context) : Nil
        env = ctx.global_env
        ctx.config.before.hooks.each_with_index do |hook, index|
          command = ctx.render(hook, "before.hooks[#{index}]")
          ctx.logger.info(hook)
          # Logged line by line while the hook runs: under --verbose, a hook
          # that hangs shows how far it went.
          status, output = Subprocess.run("sh", ["-c", command], chdir: ctx.dir, env: env, clear_env: true) do |line|
            ctx.logger.debug(line)
          end
          text = output.strip
          unless status.success?
            raise HookError.new("before hook failed (#{Subprocess.describe(status)}): #{hook}\n#{text}")
          end
        end
      end
    end
  end
end
