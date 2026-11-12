require "../context"
require "../pipe"
require "../validator"

module Crystalreleaser
  module Pipes
    # Static validation of the config, plus the checks that must fail before
    # any build rather than after half an hour of compiling: the tokens and
    # repositories of a release that will publish.
    class Validate < Pipe
      def name : String
        "validate"
      end

      def description : String
        "validating configuration"
      end

      def skippable? : Bool
        false
      end

      def run(ctx : Context) : Nil
        Validator.new(ctx.config, ctx.host).run!.each { |warning| ctx.logger.warn(warning) }
        check_token(ctx)
      end

      private def check_token(ctx : Context) : Nil
        options = ctx.options
        return unless options.publish?
        return if options.snapshot? || options.skip.includes?("publish")
        unless ctx.github_token
          raise ConfigError.new("publishing needs GITHUB_TOKEN or GH_TOKEN: set one, or use --skip=publish or --snapshot")
        end
        # Without the release, nothing is pushed to the tap or the registry
        # either: see Homebrew.publishing?.
        return if options.skip.includes?("release")
        ctx.release_repo
        check_repositories(ctx)
      end

      # The tap and the registry are pushed to after the release is public:
      # a missing repository or token must fail here, not there.
      private def check_repositories(ctx : Context) : Nil
        skip = ctx.options.skip
        unless skip.includes?("homebrew")
          ctx.config.brews.each_with_index do |brew, index|
            next if brew.skip_upload == "true"
            repository = brew.repository || raise ConfigError.new("brews[#{index}].repository is required to publish the formula")
            ctx.repository_client(repository, "brews[#{index}].repository")
          end
        end
        unless skip.includes?("aqua")
          ctx.config.aqua.each_with_index do |aqua, index|
            next if aqua.skip_upload == "true"
            ctx.repository_client(aqua.repository, "aqua[#{index}].repository")
          end
        end
      end
    end
  end
end
