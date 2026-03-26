# frozen_string_literal: true

module Knowledge
  module Collectors
    class SymbolIndexCollector < BaseCollector
      include Concerns::AstGrepRunner

      PATTERNS = {
        ruby: {
          class: "class $NAME",
          module: "module $NAME",
          method: "def $NAME"
        }
      }.freeze

      LANGUAGE_EXTENSIONS = {
        ruby: %w[.rb]
      }.freeze

      def collect
        artifacts = []

        PATTERNS.each do |language, patterns|
          extensions = LANGUAGE_EXTENSIONS[language]
          patterns.each do |symbol_type, pattern|
            results = run_ast_grep(pattern, language.to_s.capitalize)
            results.each do |match|
              file_path = relative_path(match["file"])
              next unless matching_extension?(file_path, extensions)

              name = extract_name(match)
              next if name.nil? || name.empty?

              line = match.dig("range", "start", "line")
              identifier = build_identifier(file_path, symbol_type, name)
              content = match["text"].to_s

              artifacts << {
                artifact_type: "symbol",
                scope_path: file_path,
                identifier: identifier,
                content: content,
                metadata: {
                  language: language.to_s,
                  symbol_type: symbol_type.to_s,
                  name: name,
                  line: line
                },
                chunks: [
                  {
                    chunk_type: "definition",
                    content: content,
                    scope_tags: [ language.to_s, symbol_type.to_s ],
                    sequence: 0
                  }
                ]
              }
            end
          end
        end

        artifacts
      end

      def collector_type
        "symbol_index"
      end

      def tool_version
        @tool_version ||= detect_tool_version
      end

      private

      def extract_name(match)
        match.dig("metaVariables", "single", "NAME", "text")
      end

      def build_identifier(file_path, symbol_type, name)
        case symbol_type
        when :method
          "#{file_path}##{name}"
        else
          "#{file_path}::#{name}"
        end
      end

      def ast_grep_log_component
        "knowledge.symbol_index"
      end
    end
  end
end
