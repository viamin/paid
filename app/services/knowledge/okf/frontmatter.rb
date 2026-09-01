# frozen_string_literal: true

module Knowledge
  module Okf
    # OKF-compatible Markdown + YAML frontmatter shape shared by the collector
    # (Knowledge::Collectors::OkfCollector, which parses repo-local bundles)
    # and the exporter (Knowledge::Okf::Export, which renders Paid knowledge
    # back into the same shape). Keeping parse/render in one place guarantees
    # an exported file is always readable by the same collector that would
    # ingest it.
    module Frontmatter
      DELIMITER = "---"

      ParseResult = Data.define(:frontmatter, :body, :error) do
        def valid? = error.nil?
      end

      module_function

      # @spec KNOWLEDGE-OKF-002
      # @spec KNOWLEDGE-OKF-004
      def parse(raw)
        lines = raw.each_line.to_a
        closing = lines.first&.chomp == DELIMITER ? lines.drop(1).index { |line| line.chomp == DELIMITER } : nil
        return invalid("missing YAML frontmatter delimiters") unless closing

        frontmatter = YAML.safe_load(lines[1..closing].join)
        return invalid("frontmatter must be a YAML mapping") unless frontmatter.is_a?(Hash)

        body = lines[(closing + 2)..].join.strip
        return invalid("empty concept body") if body.empty?

        ParseResult.new(frontmatter: frontmatter, body: body, error: nil)
      rescue Psych::Exception => e
        invalid("invalid frontmatter YAML: #{e.message}")
      end

      # @spec KNOWLEDGE-OKF-005
      def render(frontmatter:, body:)
        yaml_body = YAML.dump(frontmatter.deep_stringify_keys).delete_prefix("---\n")
        "#{DELIMITER}\n#{yaml_body}#{DELIMITER}\n\n#{body.strip}\n"
      end

      def invalid(reason)
        ParseResult.new(frontmatter: nil, body: nil, error: reason)
      end
    end
  end
end
