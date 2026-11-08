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
      FILES_PER_PAGE = 25
      IGNORED_PATH_SEGMENTS = TreeSitterCollector::IGNORED_PATH_SEGMENTS

      def collect
        PATTERNS.flat_map do |language, patterns|
          results = collect_all_results(patterns, language, LANGUAGE_EXTENSIONS[language])
          artifacts_from_results(results, language)
        end.then { |artifacts| deduplicate_by_content(artifacts) }
      end

      # @spec KNOWLEDGE-014
      def collect_page(cursor: nil)
        artifacts, next_cursor = each_page(cursor:)
        [ deduplicate_by_content(artifacts.to_a), next_cursor ]
      end

      # @spec KNOWLEDGE-014
      def each_page(cursor: nil)
        page, has_more = source_page(cursor:)
        next_cursor = has_more ? page.last : nil
        return [ [].each, nil ] if page.empty?

        [ page_artifacts_enum(page), next_cursor ]
      end

      def collector_type
        "symbol_index"
      end

      def tool_version
        @tool_version ||= detect_tool_version
      end

      private

      def collect_all_results(patterns, language, extensions, paths: nil)
        results = []

        patterns.each do |symbol_type, pattern|
          matches = run_ast_grep(pattern, language.to_s.capitalize, paths:)
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

      # Yields each file's artifacts in path order. The page's ast-grep runs
      # are batched once per pattern (never per file), and the per-page digest
      # set keeps duplicate matched content from reaching the artifact
      # store's conflict-recovery path.
      def page_artifacts_enum(page)
        Enumerator.new do |yielder|
          seen = Set.new
          artifacts_by_file = page_artifacts_by_file(page)
          page.each do |path|
            artifacts_by_file.fetch(path, []).each do |artifact|
              next unless seen.add?(content_digest(artifact))

              yielder << artifact
            end
          end
        end
      end

      # One ast-grep run per pattern for the whole page; a page of results in
      # memory is the accepted per-shard bound.
      def page_artifacts_by_file(page)
        LANGUAGE_EXTENSIONS.each_with_object({}) do |(language, extensions), by_file|
          paths = page.select { |path| matching_extension?(path, extensions) }
          next if paths.empty?

          results = collect_all_results(PATTERNS.fetch(language), language, extensions,
            paths: paths.map { |path| File.join(scan_path, path) })
          artifacts_from_results(results, language)
            .each { |artifact| (by_file[artifact[:scope_path]] ||= []) << artifact }
        end
      end

      def artifacts_from_results(results, language)
        results.group_by { |result| result[:file_path] }.sort_by(&:first).flat_map do |file_path, file_results|
          scope_stack = build_scope_stack(file_results)
          sort_symbol_results(file_results).map do |result|
            qualified_name = qualified_scope_name(scope_stack, result)
            build_artifact(file_path, result, qualified_name, language)
          end
        end.then { |artifacts| deduplicate_by_content(artifacts) }
      end

      def build_artifact(file_path, result, qualified_name, language)
        content = result[:content]
        {
          artifact_type: "symbol",
          scope_path: file_path,
          identifier: build_identifier(file_path, result[:symbol_type], qualified_name),
          content: content,
          metadata: {
            language: language.to_s,
            symbol_type: result[:symbol_type].to_s,
            name: result[:name],
            line: result[:line]
          },
          chunks: [ { chunk_type: "definition", content: content,
            scope_tags: [ language.to_s, result[:symbol_type].to_s ], sequence: 0 } ]
        }
      end

      def source_page(cursor:)
        root = host_repo_path
        skip!("repository path not available", preserve_existing_artifacts: true) if root.blank?

        require "find"
        paths = []
        Find.find(root) do |path|
          relative = Pathname.new(path).relative_path_from(Pathname.new(root)).to_s
          if File.directory?(path)
            Find.prune if relative != "." && ignored_path?(relative)
            next
          end

          next if ignored_path?(relative) || cursor && relative <= cursor
          next unless LANGUAGE_EXTENSIONS.values.flatten.any? { |extension| relative.end_with?(extension) }

          paths << relative
          paths.sort!
          paths.pop if paths.size > FILES_PER_PAGE + 1
        rescue Errno::ENOENT, Errno::EACCES
          next
        end
        [ paths.first(FILES_PER_PAGE), paths.size > FILES_PER_PAGE ]
      end

      def ignored_path?(relative_path)
        relative_path.split(File::SEPARATOR).any? { |segment| IGNORED_PATH_SEGMENTS.include?(segment) }
      end

      def extract_name(match)
        match.dig("metaVariables", "single", "NAME", "text")
      end

      # Build a sorted list of class/module scopes from file results,
      # used to compute fully-qualified names for all symbols.
      def build_scope_stack(file_results)
        sort_symbol_results(file_results)
          .select { |r| r[:symbol_type] == :class || r[:symbol_type] == :module }
      end

      def sort_symbol_results(results)
        results.sort_by { |r| [ r[:line], r[:column] || 0, r[:symbol_type].to_s, r[:name].to_s, r[:file_path].to_s ] }
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

      # Returns the chain of enclosing class/module names for a given
      # position, by selecting prior scopes on earlier lines or on the
      # same line with a strictly smaller column offset.
      def enclosing_scopes(scope_stack, line, max_column)
        candidates = scope_stack.select do |s|
          s[:line] < line || (s[:line] == line && s[:column] < max_column)
        end
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

      # Prevent content_hash collisions within a single collector run.
      # The unique index on [collector_run_id, content_hash] rejects
      # duplicates, so keep only the first artifact per content hash.
      def deduplicate_by_content(artifacts)
        artifacts.uniq { |a| content_digest(a) }
      end

      def content_digest(artifact)
        Digest::SHA256.hexdigest(artifact[:content].to_s)
      end

      def ast_grep_log_component
        "knowledge.symbol_index"
      end
    end
  end
end
