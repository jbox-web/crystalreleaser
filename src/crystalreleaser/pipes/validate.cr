require "../context"
require "../formats/rpm"
require "../gpg"
require "../pipe"
require "../validator"

module Crystalreleaser
  module Pipes
    # Static validation of the config, plus the checks that must fail before
    # any build rather than after half an hour of compiling: the tokens and
    # repositories of a release that will publish, and what signing its
    # packages takes.
    class Validate < Pipe
      # `gpg` is the command a signed release signs with.
      def initialize(@gpg : String = "gpg")
      end

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
        check_signing(ctx)
      end

      # What the nfpm pipe needs to sign the .rpm packages of a release: the
      # key, its passphrase and gpg. Found missing here rather than once
      # every binary is built. A snapshot is left alone: it may run without
      # the key (see Context#signing_key).
      private def check_signing(ctx : Context) : Nil
        options = ctx.options
        return unless options.publish?
        return if options.snapshot? || options.skip.includes?("nfpm")
        ctx.config.nfpms.each_with_index do |nfpm, index|
          signature = nfpm.rpm.signature
          next unless signature && nfpm.formats.includes?("rpm")
          field = "nfpms[#{index}].rpm.signature"
          key = ctx.signing_key(signature.key, "#{field}.key", snapshot: false) || ""
          passphrase = ctx.render(signature.passphrase, "#{field}.passphrase")
          unless Process.find_executable(@gpg)
            raise ConfigError.new("#{field}: gpg is required to sign the .rpm packages, and #{@gpg} was not found")
          end
          trial_signature(key, passphrase, field)
        end
      end

      # Signs one byte as the nfpm pipe will sign a header: a secret pasted
      # wrong (a public key, half a key, the passphrase of another one) and a
      # signature no RPM header tag takes all show here.
      private def trial_signature(key : String, passphrase : String, field : String) : Nil
        Gpg.open(key, passphrase, command: @gpg) { |gpg| Formats::Rpm.signature_tag(gpg.sign(Bytes[0])) }
      rescue error : Gpg::Error | FormatError
        raise ConfigError.new("#{field}: #{error.message}")
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
