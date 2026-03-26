# frozen_string_literal: true

module Knowledge
  module Collectors
    class SymbolIndexCollector < BaseCollector
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
          message: "knowledge.symbol_index.parse_error",
          error: e.message,
          pattern: pattern,
          language: language
        )
        []
      end

      def execute_command(cmd)
        stdout, stderr, status = Open3.capture3(*cmd)

        unless status.success? || status.exitstatus == 1
          Rails.logger.warn(
            message: "knowledge.symbol_index.command_error",
            stderr: stderr.truncate(500),
            exit_code: status.exitstatus
          )
          return ""
        end

        stdout
      end

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
