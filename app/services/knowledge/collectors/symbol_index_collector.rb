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
          all_results = collect_all_results(patterns, language, extensions)

          all_results.group_by { |r| r[:file_path] }.each do |file_path, file_results|
            scopes = file_results
              .select { |r| r[:symbol_type] == :class || r[:symbol_type] == :module }
              .sort_by { |r| r[:line] }

            file_results.each do |result|
              enclosing = result[:symbol_type] == :method ? enclosing_scope_name(scopes, result[:line]) : nil
              identifier = build_identifier(file_path, result[:symbol_type], result[:name], enclosing)
              content = result[:content]

              artifacts << {
                artifact_type: "symbol",
                scope_path: file_path,
                identifier: identifier,
                content: content,
                metadata: {
                  language: language.to_s,
                  symbol_type: result[:symbol_type].to_s,
                  name: result[:name],
                  line: result[:line]
                },
                chunks: [
                  {
                    chunk_type: "definition",
                    content: content,
                    scope_tags: [ language.to_s, result[:symbol_type].to_s ],
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

      def collect_all_results(patterns, language, extensions)
        results = []

        patterns.each do |symbol_type, pattern|
          matches = run_ast_grep(pattern, language.to_s.capitalize)
          matches.each do |match|
            file_path = relative_path(match["file"])
            next unless matching_extension?(file_path, extensions)

            name = extract_name(match)
            next if name.nil? || name.empty?

            results << {
              file_path: file_path,
              symbol_type: symbol_type,
              name: name,
              line: match.dig("range", "start", "line"),
              content: match["text"].to_s
            }
          end
        end

        results
      end

      def extract_name(match)
        match.dig("metaVariables", "single", "NAME", "text")
      end

      # Find the nearest class/module defined before the given line.
      # This handles the common case of methods inside classes; for
      # top-level methods (no enclosing scope), returns nil.
      def enclosing_scope_name(scopes, method_line)
        enclosing = scopes.select { |s| s[:line] < method_line }.last
        enclosing&.dig(:name)
      end

      def build_identifier(file_path, symbol_type, name, enclosing_scope = nil)
        case symbol_type
        when :method
          if enclosing_scope
            "#{file_path}::#{enclosing_scope}##{name}"
          else
            "#{file_path}##{name}"
          end
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
