require "../spec_helper"

private VARS = {
  "ProjectName" => "ssherlock",
  "Version"     => "1.2.3-rc.1",
  "Tag"         => "v1.2.3-rc.1",
  "Os"          => "linux",
  "Arch"        => "arm64",
}

private def render(source : String, vars = VARS, env = {"HOME_TAP" => "secret"}) : String
  Crystalreleaser::Template.parse(source, "spec.field").render(vars, env)
end

private def template_error(source : String, vars = VARS, env = {} of String => String) : String
  error = expect_raises(Crystalreleaser::TemplateError) do
    Crystalreleaser::Template.parse(source, "archives[0].name_template").render(vars, env)
  end
  error.message.to_s
end

describe Crystalreleaser::Template do
  describe "variables" do
    it "leaves text without actions untouched" do
      render("checksums.txt").should eq("checksums.txt")
    end

    it "substitutes several variables" do
      render("{{ .ProjectName }}_{{ .Version }}_{{ .Os }}_{{ .Arch }}")
        .should eq("ssherlock_1.2.3-rc.1_linux_arm64")
    end

    it "tolerates missing or extra spaces inside the braces" do
      render("{{.Tag}}|{{   .Tag   }}").should eq("v1.2.3-rc.1|v1.2.3-rc.1")
    end

    it "reads environment variables through .Env" do
      render("{{ .Env.HOME_TAP }}").should eq("secret")
    end

    it "keeps a single brace as text" do
      render("a { b } c").should eq("a { b } c")
    end
  end

  describe "filters" do
    it "applies upper and lower" do
      render("{{ .Os | upper }}-{{ .ProjectName | upper | lower }}").should eq("LINUX-ssherlock")
    end

    it "applies replace with two quoted arguments" do
      render(%({{ .Version | replace "-" "_" }})).should eq("1.2.3_rc.1")
    end

    it "applies trimprefix" do
      render(%({{ .Tag | trimprefix "v" }})).should eq("1.2.3-rc.1")
    end

    it "applies trimsuffix" do
      render(%({{ .Tag | trimsuffix ".1" }})).should eq("v1.2.3-rc")
    end

    it "quotes a value for the shell with shellquote, and leaves a plain one as it is" do
      vars = {"Branch" => "x;touch PWNED", "Version" => "1.2.3"}
      Crystalreleaser::Template.render("echo {{ .Branch | shellquote }} {{ .Version | shellquote }}", "hook", vars)
        .should eq("echo 'x;touch PWNED' 1.2.3")
    end

    it "accepts a filter after an argument that is not ASCII" do
      Crystalreleaser::Template.render(%({{ .Tag | replace "é" "e" | upper }}), "f", {"Tag" => "été"}).should eq("ETE")
    end

    it "does not take a }} inside a quoted argument for the end of the action" do
      Crystalreleaser::Template.render(%({{ .Tag | replace "}}" "x" }}), "f", {"Tag" => "a}}b"}).should eq("axb")
    end

    it "writes a quoted string as it is, which is how a literal {{ is written" do
      render(%(docker inspect --format '{{ "{{" }}.Id{{ "}}" }}' x)).should eq("docker inspect --format '{{.Id}}' x")
    end

    it "honours escaped quotes in arguments" do
      render(%({{ .Os | replace "linux" "a\\"b" }})).should eq(%(a"b))
    end
  end

  describe "escapes in a quoted argument" do
    it "reads \\n and \\t as a line break and a tab" do
      Crystalreleaser::Template.render(%q({{ .Branch | replace "\n" " " | replace "\t" "-" }}), "f", {"Branch" => "a\nb\tc"})
        .should eq("a b-c")
    end

    it "reads two backslashes as one" do
      Crystalreleaser::Template.render(%q({{ .Branch | replace "\\" "/" }}), "f", {"Branch" => "a\\b"}).should eq("a/b")
    end

    it "refuses an escape it does not know, rather than dropping the backslash" do
      expect_raises(Crystalreleaser::TemplateError, %q(f: unknown escape \d in a string (known: \n, \t, \\, \"))) do
        Crystalreleaser::Template.parse(%q({{ .Branch | replace "\d" "x" }}), "f")
      end
    end
  end

  describe "errors" do
    it "names an unknown variable and the config field" do
      template_error("{{ .Nope }}")
        .should eq("archives[0].name_template: unknown variable .Nope")
    end

    it "names a known variable that is not available in this field" do
      template_error("{{ .Binary }}")
        .should eq("archives[0].name_template: variable .Binary is not available here")
    end

    it "names a missing environment variable" do
      template_error("{{ .Env.HOMEBREW_TAP_TOKEN }}")
        .should eq("archives[0].name_template: environment variable HOMEBREW_TAP_TOKEN is not set")
    end

    it "reports an unclosed action" do
      template_error("{{ .Version")
        .should eq("archives[0].name_template: unclosed action, missing '}}'")
    end

    it "reports an unknown filter" do
      template_error("{{ .Version | shout }}")
        .should eq("archives[0].name_template: unknown function shout")
    end

    it "reports a wrong argument count" do
      template_error(%({{ .Version | replace "a" }}))
        .should eq("archives[0].name_template: function replace takes 2 argument(s), got 1")
    end

    it "reports an action that does not start with a variable" do
      template_error("{{ upper }}")
        .should eq("archives[0].name_template: expected a variable such as .Version, got 'upper'")
    end

    it "is raised at parse time for syntax and unknown names" do
      expect_raises(Crystalreleaser::TemplateError, "x: unknown variable .Nope") do
        Crystalreleaser::Template.parse("{{ .Nope }}", "x")
      end
    end
  end
end
