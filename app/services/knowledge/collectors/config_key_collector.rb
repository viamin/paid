# frozen_string_literal: true

module Knowledge
  module Collectors
    class ConfigKeyCollector < BaseCollector
      include Concerns::AstGrepRunner

      PATTERNS = {
        ruby: [
          { pattern: 'ENV["$KEY"]', extract: "KEY" },
          { pattern: 'ENV.fetch("$KEY")', extract: "KEY" }
        ]
      }.freeze

      LANGUAGE_EXTENSIONS = {
        ruby: %w[.rb]
      }.freeze

      def collect
        artifacts = []

        PATTERNS.each do |language, patterns|
          extensions = LANGUAGE_EXTENSIONS[language]
          lang_name = language.to_s.capitalize

          patterns.each do |pattern_config|
            results = run_ast_grep(pattern_config[:pattern], lang_name)
            results.each do |match|
              file_path = relative_path(match["file"])
              next unless matching_extension?(file_path, extensions)

              key = extract_key(match, pattern_config[:extract])
              next if key.nil? || key.empty?

              line = match.dig("range", "start", "line")
              content = match["text"].to_s

              artifacts << build_artifact(key, file_path, line, content, language)
            end
          end
        end

        deduplicate(artifacts)
      end

      def collector_type
        "config_key"
      end

      def tool_version
        @tool_version ||= detect_tool_version
      end

      private

      def extract_key(match, variable_name)
        match.dig("metaVariables", "single", variable_name, "text")
      end

      def build_artifact(key, file_path, line, content, language)
        {
          artifact_type: "config_key",
          scope_path: file_path,
          identifier: key,
          content: content,
          metadata: {
            key: key,
            file_path: file_path,
            line: line,
            language: language.to_s
          },
          chunks: [
            {
              chunk_type: "evidence",
              content: "#{file_path}:#{line} — #{content}",
              scope_tags: [ language.to_s, "config" ],
              sequence: 0
            }
          ]
        }
      end

      def deduplicate(artifacts)
        artifacts.uniq { |a| [ a[:identifier], a[:scope_path] ] }
      end

      def ast_grep_log_component
        "knowledge.config_key"
      end
    end
  end
end
