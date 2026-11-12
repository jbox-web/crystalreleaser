require "../context"
require "../git"
require "../pipe"

module Crystalreleaser
  module Pipes
    # The commits since the previous tag, filtered and grouped, written to
    # dist/CHANGELOG.md and kept as the release body. --release-notes
    # replaces it with a hand-written file.
    class Changelog < Pipe
      # {full sha, subject}, newest first as `git log` gives them.
      alias Commit = {String, String}

      def name : String
        "changelog"
      end

      def description : String
        "generating changelog"
      end

      def run(ctx : Context) : Nil
        text = Changelog.compute(ctx)
        File.write(ctx.dist_path("CHANGELOG.md"), text)
        ctx.changelog = text
        ctx.logger.info("CHANGELOG.md")
      end

      # The release notes file when given, else the changelog from git.
      def self.compute(ctx : Context) : String
        if notes = ctx.options.release_notes
          path = File.expand_path(notes, ctx.dir)
          raise UsageError.new("release notes file not found: #{notes}") unless File.file?(path)
          return File.read(path)
        end
        render(commits(ctx), ctx.config.changelog)
      end

      # Commits after the previous tag, or every commit when there is none.
      def self.commits(ctx : Context) : Array(Commit)
        range = ctx.previous_tag.try { |tag| "#{tag}..HEAD" } || "HEAD"
        output = Crystalreleaser::Git.new(ctx.dir).run("log", "--no-decorate", "--format=%H%x00%s", range, "--")
        output.lines.compact_map do |line|
          sha, _, subject = line.partition('\0')
          {sha, subject} unless sha.empty?
        end
      end

      def self.render(commits : Array(Commit), config : Config::Changelog) : String
        excludes = config.filters.exclude.map { |pattern| Regex.new(pattern) }
        kept = commits.reject { |(_, subject)| excludes.any?(&.matches?(subject)) }
        kept.reverse! if config.sort == "asc"

        # Blocks separated by one blank line; the text ends with a single
        # newline.
        blocks = ["## Changelog\n"]
        if config.groups.empty?
          blocks << list(kept) unless kept.empty?
        else
          grouped(config.groups, kept).each do |title, entries|
            blocks << "### #{title}\n" << list(entries) unless entries.empty?
          end
        end
        blocks.join('\n')
      end

      # Each commit goes to the first group whose regexp matches; a group
      # without regexp takes whatever is left.
      private def self.grouped(groups : Array(Config::ChangelogGroup), commits : Array(Commit)) : Array({String, Array(Commit)})
        buckets = groups.map { |group| {group.title, [] of Commit} }
        patterns = groups.map { |group| group.regexp.try { |regexp| Regex.new(regexp) } }
        commits.each do |commit|
          index = patterns.index { |pattern| pattern.nil? || pattern.matches?(commit[1]) }
          buckets[index][1] << commit if index
        end
        buckets
      end

      private def self.list(commits : Array(Commit)) : String
        commits.join { |(sha, subject)| "* #{sha[0, 7]} #{subject}\n" }
      end
    end
  end
end
