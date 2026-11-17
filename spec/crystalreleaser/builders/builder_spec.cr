require "../../spec_helper"

describe Crystalreleaser::Builders do
  describe ".triple" do
    it "maps every supported platform to its LLVM triple" do
      {
        {"linux", "amd64", true}   => "x86_64-linux-musl",
        {"linux", "amd64", false}  => "x86_64-linux-gnu",
        {"linux", "arm64", true}   => "aarch64-linux-musl",
        {"linux", "arm64", false}  => "aarch64-linux-gnu",
        {"darwin", "amd64", false} => "x86_64-apple-darwin",
        {"darwin", "arm64", false} => "aarch64-apple-darwin",
        {"freebsd", "amd64", true} => "x86_64-portbld-freebsd",
      }.each do |(os, arch, static), triple|
        Crystalreleaser::Builders.triple(os, arch, static).should eq(triple)
      end
    end

    it "rejects an unknown platform" do
      expect_raises(Crystalreleaser::BuildError, "no target triple for plan9/amd64") do
        Crystalreleaser::Builders.triple("plan9", "amd64", false)
      end
    end
  end

  describe ".file_warnings" do
    it "accepts a static linux amd64 ELF" do
      Crystalreleaser::Builders.file_warnings(
        "ELF 64-bit LSB executable, x86-64, version 1 (SYSV), statically linked, stripped",
        "linux", "amd64", static: true).should be_empty
    end

    it "accepts a static-pie linux arm64 ELF" do
      Crystalreleaser::Builders.file_warnings(
        "ELF 64-bit LSB pie executable, ARM aarch64, version 1 (SYSV), static-pie linked, stripped",
        "linux", "arm64", static: true).should be_empty
    end

    it "accepts Mach-O binaries of both architectures" do
      Crystalreleaser::Builders.file_warnings("Mach-O 64-bit executable arm64", "darwin", "arm64", static: false).should be_empty
      Crystalreleaser::Builders.file_warnings("Mach-O 64-bit executable x86_64", "darwin", "amd64", static: false).should be_empty
    end

    it "warns about a wrong architecture" do
      Crystalreleaser::Builders.file_warnings("Mach-O 64-bit executable x86_64", "darwin", "arm64", static: false)
        .should eq(["expected an arm64 binary, `file` reports: Mach-O 64-bit executable x86_64"])
    end

    it "warns about a dynamic binary where a static one was asked" do
      Crystalreleaser::Builders.file_warnings(
        "ELF 64-bit LSB pie executable, x86-64, version 1 (SYSV), dynamically linked, interpreter /lib/ld-musl-x86_64.so.1",
        "linux", "amd64", static: true)
        .should eq(["expected a statically linked binary, `file` reports: ELF 64-bit LSB pie executable, x86-64, " \
                    "version 1 (SYSV), dynamically linked, interpreter /lib/ld-musl-x86_64.so.1"])
    end
  end

  # A darwin binary may only depend on what every Mac has: /usr/lib and
  # /System/Library. Anything else (Homebrew, MacPorts, Nix, a library next to
  # the binary) is missing on the Mac it is installed on.
  describe ".foreign_libraries" do
    it "lists every library outside /usr/lib and /System/Library, Homebrew's on both architectures" do
      arm64 = <<-TEXT
        dist/toy:
        \t/opt/homebrew/opt/openssl@4/lib/libssl.4.dylib (compatibility version 4.0.0, current version 4.0.0)
        \t/opt/homebrew/opt/openssl@4/lib/libcrypto.4.dylib (compatibility version 4.0.0, current version 4.0.0)
        \t/usr/lib/libz.1.dylib (compatibility version 1.0.0, current version 1.2.12)
        \t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1359.40.3)
        TEXT
      Crystalreleaser::Builders.foreign_libraries(arm64).should eq([
        "/opt/homebrew/opt/openssl@4/lib/libssl.4.dylib", "/opt/homebrew/opt/openssl@4/lib/libcrypto.4.dylib",
      ])
      amd64 = "dist/toy:\n\t/usr/local/opt/openssl@3/lib/libssl.3.dylib (compatibility version 3.0.0, current version 3.0.0)\n" \
              "\t/usr/local/Cellar/bdw-gc/8.2.12/lib/libgc.1.dylib (compatibility version 2.0.0, current version 2.6.0)\n"
      Crystalreleaser::Builders.foreign_libraries(amd64).should eq([
        "/usr/local/opt/openssl@3/lib/libssl.3.dylib", "/usr/local/Cellar/bdw-gc/8.2.12/lib/libgc.1.dylib",
      ])
    end

    it "accepts the system libraries and frameworks, and reads each slice of a universal binary" do
      clean = "dist/toy (architecture arm64):\n\t/usr/lib/libiconv.2.dylib (compatibility version 7.0.0, current version 7.0.0)\n" \
              "\t/System/Library/Frameworks/Security.framework/Versions/A/Security (compatibility version 1.0.0, current version 61040.1.3)\n" \
              "dist/toy (architecture x86_64):\n\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1351.0.0)\n"
      Crystalreleaser::Builders.foreign_libraries(clean).should be_empty
    end

    it "rejects the libraries found through a path relative to the binary, and other package managers" do
      text = "dist/toy:\n\t@rpath/libfoo.dylib (compatibility version 1.0.0, current version 1.0.0)\n" \
             "\t/opt/local/lib/libbar.dylib (compatibility version 1.0.0, current version 1.0.0)\n" \
             "\t/nix/store/abc-zlib/lib/libz.dylib (compatibility version 1.0.0, current version 1.0.0)\n"
      Crystalreleaser::Builders.foreign_libraries(text)
        .should eq(["@rpath/libfoo.dylib", "/opt/local/lib/libbar.dylib", "/nix/store/abc-zlib/lib/libz.dylib"])
    end
  end

  describe ".check_darwin_libraries" do
    it "accepts a binary that only links system libraries" do
      pending_unless_macos!
      pending_tool!("cc")
      pending_tool!("otool")
      Fixture.project do |project|
        project.write("clean.c", "int main(void) { return 0; }\n")
        run_tool(["cc", "-o", project.path("clean"), project.path("clean.c")])
        Crystalreleaser::Builders.check_darwin_libraries(project.path("clean"), "toy darwin/arm64").should be_nil
      end
    end

    it "fails on a binary linked to a Homebrew library, listing it" do
      pending_unless_macos!
      pending_tool!("cc")
      pending_tool!("otool")
      prefix = pending_homebrew!("openssl@4")
      Fixture.project do |project|
        project.write("linked.c", "#include <openssl/crypto.h>\nint main(void) { return OpenSSL_version_num() == 0; }\n")
        run_tool(["cc", "-o", project.path("linked"), project.path("linked.c"), "-I#{prefix}/include", "-L#{prefix}/lib", "-lcrypto"])
        error = expect_raises(Crystalreleaser::BuildError) do
          Crystalreleaser::Builders.check_darwin_libraries(project.path("linked"), "toy darwin/arm64")
        end
        message = error.message.to_s
        message.should start_with("toy darwin/arm64: the binary depends on libraries macOS does not ship, so it only starts " \
                                  "on a Mac that has them at the same path:\n      ")
        # Indented under the error, which the build lists among others.
        message.should match(%r{\n      (/opt/homebrew|/usr/local)/\S*libcrypto\.\d+\.dylib\n})
        message.should end_with("\n    link them statically (static_libs) or drop them")
      end
    end

    it "says the libraries are not checked when otool is missing" do
      Fixture.project do |project|
        project.write("toy", "not a binary")
        Crystalreleaser::Builders.check_darwin_libraries(project.path("toy"), "toy darwin/arm64", otool: "no-such-otool")
          .should eq("toy darwin/arm64: no-such-otool is not installed: the libraries the binary loads are not checked")
      end
    end
  end

  describe ".capture" do
    # `seq 1 200000` prints 1 288 895 bytes: 9 numbers of 1 digit, 90 of 2,
    # 900 of 3, 9 000 of 4, 90 000 of 5 and 100 001 of 6, one newline each.
    it "returns every byte of a command that floods stdout and stderr at once" do
      done = Channel({Bool, String}).new(1)
      spawn { done.send(Crystalreleaser::Builders.capture(["sh", "-c", "seq 1 200000 & seq 1 200000 >&2; wait"])) }
      select
      when result = done.receive
        result[0].should be_true
        result[1].bytesize.should eq(2_577_790)
        result[1].count('\n').should eq(400_000)
      when timeout(60.seconds)
        fail "the command was still being read after 60 seconds"
      end
    end

    it "reports a missing command" do
      Crystalreleaser::Builders.capture(["crystalreleaser-no-such-command"])
        .should eq({false, "crystalreleaser-no-such-command: command not found"})
    end
  end
end
