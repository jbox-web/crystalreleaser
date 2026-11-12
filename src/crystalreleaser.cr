# Process entry point, and the only file that calls `exit`. Everything else
# lives under src/crystalreleaser/ and can be required from a spec without
# starting the CLI. VERSION is defined in src/crystalreleaser/version.cr, from
# the CRYSTALRELEASER_VERSION macro env at compile time.
require "./crystalreleaser/cli"

exit Crystalreleaser::CLI.new.run(ARGV)
