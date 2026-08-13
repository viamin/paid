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
          if containerized?
            return execute_ast_grep_in_container(cmd)
          end

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

        def execute_ast_grep_in_container(cmd)
          run_command(*cmd, timeout: 60)
        rescue RuntimeError, Knowledge::ContainerizedRunner::ContainerError => e
          # ast-grep returns exit 1 when no matches found — not an error.
          return "" if e.message.include?("exit 1")

          Rails.logger.warn(
            message: "#{ast_grep_log_component}.command_error",
            error: e.message.truncate(500)
          )
          ""
        end

        def detect_tool_version
          if containerized?
            begin
              return run_command("ast-grep", "--version", timeout: 10).strip
            rescue RuntimeError, Knowledge::ContainerizedRunner::ContainerError
              return nil
            end
          end

          stdout, _stderr, status = Open3.capture3("ast-grep", "--version")
          status.success? ? stdout.strip : nil
        rescue Errno::ENOENT
          nil
        end

        def relative_path(file_path)
          return file_path if file_path.nil?

          base = resolve_repo_path || scan_path
          expanded_file = Pathname.new(File.expand_path(file_path))
          expanded_scan = Pathname.new(File.expand_path(base))
          expanded_file.relative_path_from(expanded_scan).to_s
        rescue ArgumentError
          file_path
        end

        def matching_extension?(file_path, extensions)
          extensions.any? { |ext| file_path.end_with?(ext) }
        end

        def scan_path
          @scan_path ||= if containerized?
            # Commands execute inside the container where the repo is at workspace_mount.
            container_runner.options[:workspace_mount]
          else
            options[:scan_path] || resolve_repo_path || "."
          end
        end

        # Override in the including collector for a more specific log prefix.
        def ast_grep_log_component
          "knowledge.ast_grep"
        end
      end
    end
  end
end
