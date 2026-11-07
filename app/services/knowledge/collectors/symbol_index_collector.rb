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

      IGNORED_PATH_SEGMENTS = %w[
        .git
        node_modules
        vendor
        tmp
        log
        storage
        coverage
      ].freeze

      FILES_PER_PAGE = 25

      def collect
        artifacts = []

        PATTERNS.each do |language, patterns|
          extensions = LANGUAGE_EXTENSIONS[language]
          all_results = collect_all_results(patterns, language, extensions)
          artifacts.concat(build_file_artifacts(language, all_results))
        end

        deduplicate_by_content(artifacts)
      end

      # Each page is a separate GoodJob perform. Scoping ast-grep to a bounded
      # page of files keeps matches, results, and artifacts bounded in Puma,
      # the same way TreeSitterCollector#collect_page does.
      # @spec KNOWLEDGE-016
      def collect_page(cursor: nil)
        page, has_more = source_page(cursor:)
        next_cursor = has_more ? page.last : nil
        return [ [], nil ] if page.empty?

        artifacts = []
        PATTERNS.each do |language, patterns|
          extensions = LANGUAGE_EXTENSIONS[language]
          matching = page.select { |path| matching_extension?(path, extensions) }
          next if matching.empty?

          all_results = collect_all_results(patterns, language, extensions,
            paths: matching.map { |path| File.join(scan_path, path) })
          artifacts.concat(build_file_artifacts(language, all_results))
        end

        [ deduplicate_by_content(artifacts), next_cursor ]
      end

      def collector_type
        "symbol_index"
      end

      def tool_version
        @tool_version ||= detect_tool_version
      end

      private

      # Qualified names and identifiers are computed from only the results
      # already grouped per file, so paging by file cannot change them.
      def build_file_artifacts(language, all_results)
        all_results
          .group_by { |r| r[:file_path] }
          .sort_by { |file_path, _| file_path }
          .flat_map do |file_path, file_results|
          sorted_file_results = sort_symbol_results(file_results)
          scope_stack = build_scope_stack(sorted_file_results)

          sorted_file_results.map do |result|
            qualified_name = qualified_scope_name(scope_stack, result)
            identifier = build_identifier(file_path, result[:symbol_type], qualified_name)
            content = result[:content]

            {
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

      def collect_all_results(patterns, language, extensions, paths: nil)
        results = []

        patterns.each do |symbol_type, pattern|
          matches = paths ? run_ast_grep(pattern, language.to_s.capitalize, paths: paths) :
            run_ast_grep(pattern, language.to_s.capitalize)
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
        artifacts.uniq { |a| Digest::SHA256.hexdigest(a[:content].to_s) }
      end

      # Enumerates a bounded, stable page of eligible source files starting
      # just after the given cursor (a relative path), so a retried perform
      # resumes from the same point instead of re-scanning from the start.
      def source_page(cursor:)
        root = host_repo_path
        skip!("repository path not available", preserve_existing_artifacts: true) if root.blank?

        require "find"
        extensions = LANGUAGE_EXTENSIONS.values.flatten
        paths = []
        after_cursor = cursor.nil?
        catch(:page_full) do
          Find.find(root) do |path|
            relative = Pathname.new(path).relative_path_from(Pathname.new(root)).to_s
            if File.directory?(path)
              Find.prune if relative != "." && ignored_path?(relative)
              next
            end

            next if ignored_path?(relative) || !matching_extension?(relative, extensions)
            unless after_cursor
              after_cursor = true if relative == cursor
              next
            end

            paths << relative
            throw :page_full if paths.size > FILES_PER_PAGE
          rescue Errno::ENOENT, Errno::EACCES
            next
          end
        end
        raise ArgumentError, "collector cursor no longer exists: #{cursor}" unless after_cursor

        [ paths.first(FILES_PER_PAGE), paths.size > FILES_PER_PAGE ]
      end

      def ignored_path?(relative_path)
        relative_path.split(File::SEPARATOR).any? { |segment| IGNORED_PATH_SEGMENTS.include?(segment) }
      end

      def ast_grep_log_component
        "knowledge.symbol_index"
      end
    end
  end
end
