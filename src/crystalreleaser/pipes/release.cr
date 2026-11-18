require "../artifact"
require "../context"
require "../github/client"
require "./checksum"

module Crystalreleaser
  module Pipes
    # Shared by the publishing pipes: never in a snapshot.
    abstract class PublishPipe < Pipe
      def group : String?
        "publish"
      end

      def skip?(ctx : Context) : String?
        "snapshot" if ctx.snapshot?
      end
    end

    # The GitHub release of the tag, filled with the archives, packages,
    # checksums and the public key of signed packages. A new release stays a draft until every asset is uploaded,
    # and is published last: a run that fails halfway never leaves a public
    # release with missing files, and running it again resumes that draft.
    # An existing release keeps the state it has.
    class Release < PublishPipe
      UPLOADED = {Artifact::Type::Archive, Artifact::Type::LinuxPackage, Artifact::Type::Checksum,
                  Artifact::Type::PublicKey}

      def name : String
        "release"
      end

      def description : String
        "publishing the GitHub release"
      end

      def run(ctx : Context) : Nil
        owner, repo = ctx.release_repo
        config = ctx.config.release
        client = ctx.github_client
        tag = ctx.version_info.tag

        existing = client.find_release(owner, repo, tag)
        draft = existing ? (existing["draft"]?.try(&.as_bool?) || false) : true
        payload = {
          tag_name: tag,
          # Without it, GitHub creates a tag that is not on the remote yet from
          # the default branch: the release would then name another commit
          # than the one the binaries were built from.
          target_commitish: ctx.commit,
          name:             ctx.render(config.name_template, "release.name_template"),
          body:             body(ctx),
          draft:            draft,
          prerelease:       prerelease?(ctx),
        }
        release =
          if existing
            client.update_release(owner, repo, existing["id"].as_i64, payload)
            existing
          else
            client.create_release(owner, repo, payload)
          end
        release_id = release["id"].as_i64
        ctx.logger.info("#{existing ? "updated" : "created"} #{draft ? "draft " : ""}release #{tag}", repo: "#{owner}/#{repo}")

        upload_assets(ctx, client, owner, repo, release_id)

        if draft && !config.draft?
          # make_latest only counts here: GitHub does not keep the one given
          # when the draft was created.
          client.update_release(owner, repo, release_id, {draft: false, make_latest: config.make_latest})
          ctx.logger.info("published release #{tag}")
        end
      end

      private def upload_assets(ctx : Context, client : Github::Client, owner : String, repo : String, release_id : Int64) : Nil
        tag = ctx.version_info.tag
        assets = client.list_assets(owner, repo, release_id).to_h { |asset| {asset["name"].as_s, asset} }
        ctx.artifacts.all.select { |artifact| UPLOADED.includes?(artifact.type) }.each do |artifact|
          file = File.join(ctx.dir, artifact.path)
          if asset = assets[artifact.name]?
            case existing_asset(ctx, asset, artifact, file)
            in .identical?
              ctx.logger.info("#{artifact.name} is already uploaded")
              next
            in .leftover?, .replaceable?
              client.delete_asset(owner, repo, asset["id"].as_i64)
            in .conflicting?
              raise GithubError.new("asset #{artifact.name} already exists on release #{tag}; " \
                                    "set release.replace_existing_artifacts: true to replace it")
            end
          end
          client.upload_asset(owner, repo, release_id, artifact.name, file)
          ctx.logger.info("uploaded #{artifact.name}")
        end
      end

      private enum Existing
        # An empty asset a failed upload left: GitHub says it can be deleted.
        Leftover
        # Same sha256 as the local file: nothing to do.
        Identical
        Replaceable
        Conflicting
      end

      private def existing_asset(ctx : Context, asset : JSON::Any, artifact : Artifact, file : String) : Existing
        state = asset["state"]?.try(&.as_s?)
        return Existing::Leftover if state && state != "uploaded"
        digest = asset["digest"]?.try(&.as_s?)
        return Existing::Identical if digest && digest == "sha256:#{artifact.sha256 ||= Checksum.sha256(file)}"
        ctx.config.release.replace_existing_artifacts? ? Existing::Replaceable : Existing::Conflicting
      end

      private def body(ctx : Context) : String
        config = ctx.config.release
        parts = [
          ctx.render(config.header, "release.header"),
          ctx.changelog.chomp,
          ctx.render(config.footer, "release.footer"),
        ].reject(&.empty?)
        parts.join("\n\n") + "\n"
      end

      # auto: a semver pre-release (1.2.0-rc.1) is published as such.
      private def prerelease?(ctx : Context) : Bool
        case ctx.config.release.prerelease
        when "true"  then true
        when "false" then false
        else              !ctx.version_info.prerelease.empty?
        end
      end
    end
  end
end
