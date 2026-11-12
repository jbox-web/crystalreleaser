require "yaml"

require "./error"

module Crystalreleaser
  # The parts of shard.yml the release defaults are derived from.
  class ShardManifest
    getter name : String
    getter version : String
    # Target name => main file, in declaration order.
    getter targets : Hash(String, String)
    # The `crystal:` version constraint, e.g. ">= 1.18.0"; empty when absent.
    getter crystal : String

    def initialize(@name : String, @version : String = "", @targets : Hash(String, String) = {} of String => String,
                   @crystal : String = "")
    end

    def self.load(dir : String) : ShardManifest
      path = File.join(dir, "shard.yml")
      raise ConfigError.new("shard.yml not found in #{dir}") unless File.file?(path)
      content =
        begin
          File.read(path)
        rescue error : File::Error
          raise ConfigError.new("cannot read shard.yml: #{error.message}")
        end
      parse(content)
    end

    # Read from the YAML nodes, not from parsed values: an unquoted `1.20`
    # is a float to YAML, and would come back as "1.2".
    def self.parse(content : String) : ShardManifest
      root = YAML::Nodes.parse(content).nodes.first?
      raise ConfigError.new("shard.yml: expected a mapping") unless root.is_a?(YAML::Nodes::Mapping)
      fields = entries(root)

      name = scalar(fields["name"]?) || raise ConfigError.new("shard.yml: missing 'name'")
      targets = {} of String => String
      if declared = fields["targets"]?
        mapping = declared.as?(YAML::Nodes::Mapping) || raise ConfigError.new("shard.yml: targets: expected a mapping of target names")
        entries(mapping).each do |target, spec|
          main = spec.as?(YAML::Nodes::Mapping).try { |node| scalar(entries(node)["main"]?) }
          raise ConfigError.new("shard.yml: targets.#{target}: expected a mapping with a 'main' key") unless main
          targets[target] = main
        end
      end
      new(name, scalar(fields["version"]?) || "", targets, scalar(fields["crystal"]?) || "")
    rescue error : YAML::ParseException
      message = error.message.to_s.gsub(/ at line \d+, column \d+/, "")
      raise ConfigError.new("shard.yml:#{error.line_number}:#{error.column_number}: #{message}")
    end

    # Key => value node of a mapping, in declaration order.
    private def self.entries(mapping : YAML::Nodes::Mapping) : Hash(String, YAML::Nodes::Node)
      result = {} of String => YAML::Nodes::Node
      mapping.nodes.each_slice(2) do |(key, value)|
        next unless key.is_a?(YAML::Nodes::Scalar)
        # YAML keeps the last one, without a word.
        raise ConfigError.new("shard.yml: duplicate key '#{key.value}'") if result.has_key?(key.value)
        result[key.value] = value
      end
      result
    end

    # The text of a scalar exactly as written, nil for anything else.
    private def self.scalar(node : YAML::Nodes::Node?) : String?
      node.as?(YAML::Nodes::Scalar).try(&.value.presence)
    end
  end
end
