# frozen_string_literal: true

require "open3"

module Knowledge
  module Collectors
    module Concerns
      # Shared helpers for collectors that shell out to the ast-grep CLI.
      # Include this module and call `run_ast_grep(pattern, language)` to
      # get parsed JSON results.  Override `ast_grep_log_component` to
      # customise the structured-log prefix.
      module AstGrepRunner
        private

        def run_ast_grep(pattern, language)
          cmd = [
            "ast-grep", "run",
            "--pattern", pattern,
            "--lang", language,
            "--json",
            scan_path
          ]

          output = execute_ast_grep(cmd)
          return [] if output.empty?

          JSON.parse(output)
        rescue JSON::ParserError => e
          Rails.logger.warn(
            message: "#{ast_grep_log_component}.parse_error",
            error: e.message,
            pattern: pattern,
            language: language
          )
          []
        end

        def execute_ast_grep(cmd)
          stdout, stderr, status = Open3.capture3(*cmd)

          unless status.success? || status.exitstatus == 1
            Rails.logger.warn(
              message: "#{ast_grep_log_component}.command_error",
              stderr: stderr.truncate(500),
              exit_code: status.exitstatus
            )
            return ""
          end

          stdout
        rescue Errno::ENOENT
          Rails.logger.warn(message: "#{ast_grep_log_component}.tool_not_found", command: cmd.first)
          ""
        end

        def detect_tool_version
          stdout, _stderr, status = Open3.capture3("ast-grep", "--version")
          status.success? ? stdout.strip : nil
        rescue Errno::ENOENT
          nil
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

        # Override in the including collector for a more specific log prefix.
        def ast_grep_log_component
          "knowledge.ast_grep"
        end
      end
    end
  end
end
