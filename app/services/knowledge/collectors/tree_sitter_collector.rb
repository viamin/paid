# frozen_string_literal: true

module Knowledge
  module Collectors
    # Extracts structural code elements (function signatures, class hierarchies,
    # module patterns) across multiple languages using ast-grep (tree-sitter based).
    # Produces rich metadata including naming style, line counts, inheritance, and
    # parameters to inform style guide suggestions.
    class TreeSitterCollector < BaseCollector
      include Concerns::AstGrepRunner

      IGNORED_PATH_SEGMENTS = %w[
        .git
        node_modules
        vendor
        tmp
        log
        storage
        coverage
      ].freeze

      LANGUAGE_CONFIG = {
        javascript: {
          extensions: %w[.js .jsx],
          lang: "JavaScript",
          patterns: {
            class_extends: {
              pattern: "class $NAME extends $PARENT { $$$BODY }", element: "class"
            },
            class_plain: { pattern: "class $NAME", element: "class" },
            function_def: {
              pattern: "function $NAME($$$PARAMS) { $$$BODY }", element: "function"
            }
          }
        },
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

      FILE_LEVEL_FALLBACKS = {
        shell: %w[.sh],
        sql: %w[.sql],
        lua: %w[.lua]
      }.freeze

      MAX_FALLBACK_FILE_BYTES = 512_000

      def collect
        ast_artifacts = collect_ast_artifacts
        fallback_artifacts = collect_file_fallback_artifacts(
          existing_paths: ast_artifacts.map { |artifact| artifact[:scope_path] }.to_set
        )

        deduplicate_by_content(ast_artifacts + fallback_artifacts).sort_by do |artifact|
          metadata = artifact[:metadata] || {}
          [
            artifact[:scope_path].to_s,
            metadata[:start_line].to_i.nonzero? || metadata[:line].to_i,
            metadata[:element_type].to_s,
            metadata[:name].to_s,
            artifact[:identifier].to_s
          ]
        end
      end

      def collector_type
        "tree_sitter"
      end

      def tool_version
        @tool_version ||= detect_tool_version
      end

      private

      def collect_ast_artifacts
        LANGUAGE_CONFIG.each_with_object([]) do |(language, config), artifacts|
          artifacts.concat(collect_language(language, config))
        end
      end

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
        line = one_indexed_line(match.dig("range", "start", "line"))
        end_line = one_indexed_line(match.dig("range", "end", "line"))

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

      def one_indexed_line(line)
        return nil if line.nil?

        line.to_i + 1
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
          chunking_strategy: "ast",
          line: result[:line],
          start_line: result[:line],
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
              scope_tags: [ result[:language].to_s, result[:element_type], "ast" ],
              sequence: 0
            }
          ]
        }
      end

      def collect_file_fallback_artifacts(existing_paths:)
        repo_files(exclude_paths: existing_paths).map do |repo_file|
          build_file_artifact(repo_file, repo_file[:language])
        end
      end

      def build_file_artifact(repo_file, language)
        line_count = repo_file[:content].lines.count

        {
          artifact_type: "structure",
          scope_path: repo_file[:relative_path],
          identifier: "#{repo_file[:relative_path]}::file",
          content: repo_file[:content],
          metadata: {
            language: language.to_s,
            element_type: "file",
            name: File.basename(repo_file[:relative_path]),
            chunking_strategy: "file_fallback",
            line: 1,
            start_line: 1,
            end_line: line_count,
            line_count: line_count,
            naming_style: "other"
          },
          chunks: [
            {
              chunk_type: "definition",
              content: repo_file[:content],
              scope_tags: [ language.to_s, "file", "file_fallback" ],
              sequence: 0
            }
          ]
        }
      end

      def repo_files(exclude_paths: Set.new)
        root = host_repo_path || scan_path
        return [] if root.blank?

        Dir.glob(File.join(root, "**", "*")).filter_map do |path|
          next unless File.file?(path)

          relative = relative_path(path)
          next if ignored_path?(relative)
          next if exclude_paths.include?(relative)
          language = fallback_language_for(relative)
          next unless language
          next unless text_file?(path)
          next if File.size(path) > MAX_FALLBACK_FILE_BYTES

          {
            absolute_path: path,
            relative_path: relative,
            language: language,
            content: File.read(path)
          }
        rescue Errno::ENOENT, Errno::EACCES
          nil
        end
      end

      def ignored_path?(relative_path)
        relative_path.split(File::SEPARATOR).any? { |segment| IGNORED_PATH_SEGMENTS.include?(segment) }
      end

      def text_file?(path)
        !File.binread(path, 1024).include?("\x00")
      rescue EOFError
        true
      end

      def fallback_language_for(relative_path)
        extension = File.extname(relative_path)

        LANGUAGE_CONFIG.each do |language, config|
          return language if config[:extensions].include?(extension)
        end

        FILE_LEVEL_FALLBACKS.each do |language, extensions|
          return language if extensions.include?(extension)
        end

        nil
      end

      # Prevent content_hash collisions within a single collector run.
      # The unique index on [collector_run_id, content_hash] rejects
      # duplicates, so keep only the first artifact per content hash.
      def deduplicate_by_content(artifacts)
        artifacts.uniq { |a| Digest::SHA256.hexdigest(a[:content].to_s) }
      end

      def ast_grep_log_component
        "knowledge.tree_sitter"
      end
    end
  end
end
