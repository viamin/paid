# frozen_string_literal: true

require "open3"

module Knowledge
  module Collectors
    class ConfigKeyCollector < BaseCollector
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

      def run_ast_grep(pattern, language)
        cmd = [
          "ast-grep", "run",
          "--pattern", pattern,
          "--lang", language,
          "--json",
          scan_path
        ]

        output = execute_command(cmd)
        return [] if output.empty?

        JSON.parse(output)
      rescue JSON::ParserError => e
        Rails.logger.warn(
          message: "knowledge.config_key.parse_error",
          error: e.message,
          pattern: pattern
        )
        []
      end

      def execute_command(cmd)
        stdout, stderr, status = Open3.capture3(*cmd)

        unless status.success? || status.exitstatus == 1
          Rails.logger.warn(
            message: "knowledge.config_key.command_error",
            stderr: stderr.truncate(500),
            exit_code: status.exitstatus
          )
          return ""
        end

        stdout
      rescue Errno::ENOENT
        Rails.logger.warn(message: "knowledge.config_key.tool_not_found", command: cmd.first)
        ""
      end

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

      def relative_path(absolute_path)
        return absolute_path unless scan_path && absolute_path&.start_with?(scan_path)

        absolute_path.delete_prefix(scan_path).delete_prefix("/")
      end

      def matching_extension?(file_path, extensions)
        extensions.any? { |ext| file_path.end_with?(ext) }
      end

      def scan_path
        @scan_path ||= options[:scan_path] || "."
      end

      def detect_tool_version
        stdout, _stderr, status = Open3.capture3("ast-grep", "--version")
        status.success? ? stdout.strip : nil
      rescue Errno::ENOENT
        nil
      end
    end
  end
end
