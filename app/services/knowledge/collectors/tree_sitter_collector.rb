# frozen_string_literal: true

module Knowledge
  module Collectors
    # Extracts structural code elements (function signatures, class hierarchies,
    # module patterns) across multiple languages using ast-grep (tree-sitter based).
    # Produces rich metadata including naming style, line counts, inheritance, and
    # parameters to inform style guide suggestions.
    class TreeSitterCollector < BaseCollector
      include Concerns::AstGrepRunner

      LANGUAGE_CONFIG = {
        ruby: {
          extensions: %w[.rb],
          lang: "Ruby",
          patterns: {
            class_with_parent: { pattern: "class $NAME < $PARENT", element: "class" },
            class_plain: { pattern: "class $NAME", element: "class" },
            module_def: { pattern: "module $NAME", element: "module" },
            method_with_params: { pattern: "def $NAME($$$PARAMS)", element: "method" },
            method_plain: { pattern: "def $NAME", element: "method" }
          }
        },
        typescript: {
          extensions: %w[.ts .tsx],
          lang: "TypeScript",
          patterns: {
            class_extends: {
              pattern: "class $NAME extends $PARENT { $$$BODY }", element: "class"
            },
            class_plain: { pattern: "class $NAME", element: "class" },
            interface_def: { pattern: "interface $NAME", element: "interface" },
            function_def: {
              pattern: "function $NAME($$$PARAMS): $RET { $$$BODY }", element: "function"
            },
            function_no_ret: {
              pattern: "function $NAME($$$PARAMS) { $$$BODY }", element: "function"
            }
          }
        },
        python: {
          extensions: %w[.py],
          lang: "Python",
          patterns: {
            class_with_parents: { pattern: "class $NAME($$$PARENTS)", element: "class" },
            class_plain: { pattern: "class $NAME", element: "class" },
            function_def: { pattern: "def $NAME", element: "function" }
          }
        },
        go: {
          extensions: %w[.go],
          lang: "Go",
          patterns: {
            struct_def: {
              pattern: "type $NAME struct { $$$BODY }", element: "struct"
            },
            interface_def: {
              pattern: "type $NAME interface { $$$BODY }", element: "interface"
            },
            function_def: { pattern: "func $NAME($$$PARAMS)", element: "function" }
          }
        }
      }.freeze

      def collect
        artifacts = []
        LANGUAGE_CONFIG.each do |language, config|
          artifacts.concat(collect_language(language, config))
        end
        artifacts
      end

      def collector_type
        "tree_sitter"
      end

      def tool_version
        @tool_version ||= detect_tool_version
      end

      private

      def collect_language(language, config)
        results = []

        config[:patterns].each_value do |pattern_config|
          matches = run_ast_grep(pattern_config[:pattern], config[:lang])
          matches.each do |match|
            file_path = relative_path(match["file"])
            next unless matching_extension?(file_path, config[:extensions])

            result = build_result(match, file_path, language, pattern_config[:element])
            results << result if result
          end
        end

        deduplicate_results(results).map { |r| build_artifact(r) }
      end

      def build_result(match, file_path, language, element_type)
        name = extract_meta_var(match, "NAME")
        return nil if name.nil? || name.empty?

        text = match["text"].to_s
        line = match.dig("range", "start", "line")
        end_line = match.dig("range", "end", "line")

        {
          file_path: file_path,
          language: language,
          element_type: element_type,
          name: name,
          text: text,
          line: line,
          end_line: end_line,
          line_count: compute_line_count(line, end_line),
          parent: extract_meta_var(match, "PARENT"),
          params: extract_params(match),
          naming_style: detect_naming_style(name)
        }
      end

      def extract_meta_var(match, var_name)
        match.dig("metaVariables", "single", var_name, "text")
      end

      def extract_params(match)
        extract_multi_var(match, "PARAMS") || extract_multi_var(match, "PARENTS")
      end

      def extract_multi_var(match, var_name)
        multi = match.dig("metaVariables", "multi", var_name)
        return nil unless multi.is_a?(Array) && multi.any?

        multi.map { |m| m["text"] }.compact.join(", ")
      end

      def compute_line_count(line, end_line)
        return 1 if line.nil? || end_line.nil?
        end_line - line + 1
      end

      def detect_naming_style(name)
        case name
        when /\A[A-Z][A-Z0-9_]*\z/ then "screaming_snake"
        when /\A[A-Z][a-zA-Z0-9]*\z/ then "pascal"
        when /\A[a-z][a-zA-Z0-9]*\z/
          name.match?(/[A-Z]/) ? "camel" : "snake"
        when /\A[a-z][a-z0-9_]*\z/ then "snake"
        else "other"
        end
      end

      # Remove duplicates when both specific and generic patterns match the
      # same element (e.g. "class Foo < Bar" also matches "class Foo").
      # Keep the more specific match.
      def deduplicate_results(results)
        results
          .group_by { |r| [ r[:file_path], r[:element_type], r[:name], r[:line] ] }
          .values
          .map { |group| group.max_by { |r| specificity(r) } }
      end

      def specificity(result)
        score = 0
        score += 1 if result[:parent]
        score += 1 if result[:params]
        score
      end

      def build_artifact(result)
        identifier = [
          result[:file_path],
          result[:element_type],
          result[:name],
          result[:line]
        ].join("::")

        metadata = {
          language: result[:language].to_s,
          element_type: result[:element_type],
          name: result[:name],
          line: result[:line],
          end_line: result[:end_line],
          line_count: result[:line_count],
          naming_style: result[:naming_style]
        }
        metadata[:parent] = result[:parent] if result[:parent]
        metadata[:params] = result[:params] if result[:params]

        {
          artifact_type: "structure",
          scope_path: result[:file_path],
          identifier: identifier,
          content: result[:text],
          metadata: metadata,
          chunks: [
            {
              chunk_type: "definition",
              content: result[:text],
              scope_tags: [ result[:language].to_s, result[:element_type] ],
              sequence: 0
            }
          ]
        }
      end

      def ast_grep_log_component
        "knowledge.tree_sitter"
      end
    end
  end
end
