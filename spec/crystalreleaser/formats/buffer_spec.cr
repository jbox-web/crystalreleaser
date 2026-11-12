require "../../spec_helper"

describe Crystalreleaser::Formats::Buffer do
  it "holds what is written to it" do
    buffer = Crystalreleaser::Formats::Buffer.new("the payload")
    buffer << "abc" << "def"
    String.new(buffer.to_slice).should eq("abcdef")
  end

  # IO::Memory stops at 2 GiB with an error that names nothing.
  it "refuses, by name, what would go over its limit" do
    buffer = Crystalreleaser::Formats::Buffer.new("the payload of toy.rpm", limit: 8_i64)
    buffer << "12345678"
    expect_raises(Crystalreleaser::FormatError, "the payload of toy.rpm is too large once compressed: it is built in memory, " \
                                                "which holds 2 GiB at most") do
      buffer << "9"
    end
  end

  it "has the limit of IO::Memory by default" do
    Crystalreleaser::Formats::Buffer::LIMIT.should eq(2_147_483_647_i64)
  end
end
