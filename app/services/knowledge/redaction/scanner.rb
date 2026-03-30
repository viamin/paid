# frozen_string_literal: true

require "yaml"

module Knowledge
  module Redaction
    class Scanner
      Match = Data.define(:pattern, :offset, :length)

      PATTERNS = begin
        config_path = if defined?(Rails) && Rails.respond_to?(:root) && Rails.root
          Rails.root.join("config", "knowledge", "redaction_patterns.yml")
        else
          File.expand_path("../../../../config/knowledge/redaction_patterns.yml", __dir__)
        end

        raw = YAML.load_file(config_path)
        raw.each_with_object({}) do |(name, pattern_str), memo|
          memo[name.to_sym] = Regexp.new(pattern_str.to_s)
        end.freeze
      end.freeze

      def self.scan(text)
        new.scan(text)
      end

      def scan(text)
        return [] if text.nil? || text.empty?

        matches = []
        PATTERNS.each do |name, regex|
          text.scan(regex) do
            md = Regexp.last_match
            matches << Match.new(pattern: name, offset: md.begin(0), length: md[0].length)
          end
        end

        matches.sort_by(&:offset)
      end
    end
  end
end
