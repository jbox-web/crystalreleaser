require "../spec_helper"

private def log(level = Crystalreleaser::Logger::Level::Info, color = false, & : Crystalreleaser::Logger ->) : String
  io = IO::Memory.new
  yield Crystalreleaser::Logger.new(io, level, color)
  io.to_s
end

describe Crystalreleaser::Logger do
  it "prints one line per step and indents nested lines" do
    output = log do |logger|
      logger.step("building")
      logger.nest do
        logger.info("toy", os: "linux", arch: "amd64")
        logger.nest { logger.info("done") }
      end
      logger.step("archiving")
    end

    output.should eq(
      "• building\n" \
      "  • toy os=linux arch=amd64\n" \
      "    • done\n" \
      "• archiving\n"
    )
  end

  it "marks warnings and keeps them under --quiet" do
    output = log(Crystalreleaser::Logger::Level::Warn) do |logger|
      logger.step("hidden")
      logger.nest { logger.warn("careful") }
    end

    output.should eq("  ⚠ careful\n")
  end

  it "prints debug lines only under --verbose" do
    log(&.debug("detail")).should be_empty
    log(Crystalreleaser::Logger::Level::Debug, &.debug("detail")).should eq("  detail\n")
  end

  it "does not colour when asked not to" do
    log(&.warn("careful")).should_not contain("\e[")
  end

  it "colours when asked to" do
    log(color: true, &.warn("careful")).should contain("\e[33m")
  end

  it "does not colour a stream that is not a terminal by default" do
    io = IO::Memory.new
    Crystalreleaser::Logger.new(io).warn("careful")
    io.to_s.should eq("⚠ careful\n")
  end

  it "restores the indentation when the nested block raises" do
    output = log do |logger|
      begin
        logger.nest { raise "boom" }
      rescue
      end
      logger.step("after")
    end
    output.should eq("• after\n")
  end
end
