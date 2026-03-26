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
            scope_stack = build_scope_stack(file_results)

            file_results.each do |result|
              qualified_name = qualified_scope_name(scope_stack, result)
              identifier = build_identifier(file_path, result[:symbol_type], qualified_name)
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
              column: match.dig("range", "start", "column") || 0,
              content: match["text"].to_s
            }
          end
        end

        results
      end

      def extract_name(match)
        match.dig("metaVariables", "single", "NAME", "text")
      end

      # Build a sorted list of class/module scopes from file results,
      # used to compute fully-qualified names for all symbols.
      def build_scope_stack(file_results)
        file_results
          .select { |r| r[:symbol_type] == :class || r[:symbol_type] == :module }
          .sort_by { |r| r[:line] }
      end

      # Compute the fully-qualified name for a symbol by walking enclosing
      # class/module scopes. For classes/modules this produces e.g.
      # "Outer::Inner"; for methods, "Outer::Inner#method_name".
      def qualified_scope_name(scope_stack, result)
        enclosing = enclosing_scopes(scope_stack, result[:line], result[:column])

        case result[:symbol_type]
        when :method
          prefix = enclosing.empty? ? nil : enclosing.join("::")
          prefix ? "#{prefix}##{result[:name]}" : result[:name]
        else
          (enclosing + [ result[:name] ]).join("::")
        end
      end

      # Returns the chain of enclosing class/module names for a given line,
      # by selecting prior scopes with a strictly smaller column offset.
      def enclosing_scopes(scope_stack, line, max_column)
        candidates = scope_stack.select { |s| s[:line] < line }
        return [] if candidates.empty?

        # Walk backwards, collecting scopes whose column is strictly less
        # than both the target and each previously collected scope.
        chain = []
        threshold = max_column
        candidates.reverse_each do |scope|
          if scope[:column] < threshold
            chain << scope[:name]
            threshold = scope[:column]
          end
        end

        chain.reverse
      end

      def build_identifier(file_path, symbol_type, qualified_name)
        case symbol_type
        when :method
          if qualified_name.include?("#")
            "#{file_path}::#{qualified_name}"
          else
            "#{file_path}##{qualified_name}"
          end
        else
          "#{file_path}::#{qualified_name}"
        end
      end

      def ast_grep_log_component
        "knowledge.symbol_index"
      end
    end
  end
end
