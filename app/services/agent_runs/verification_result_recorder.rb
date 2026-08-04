# frozen_string_literal: true

require "json"

module AgentRuns
  # @spec LIVE-PREVIEW-005
  class VerificationResultRecorder
    VALID_STATUSES = %w[passed failed skipped not_run].freeze
    LOG_TAIL_LINES = 40
    LOG_TAIL_CHUNK_BYTES = 4096
    LOG_TAIL_MAX_BYTES = 32 * 1024

    def self.call(...)
      new(...).call
    end

    def initialize(agent_run:, repo_path:, fallback_result: nil, logger: Rails.logger)
      @agent_run = agent_run
      @repo_path = repo_path
      @fallback_result = fallback_result
      @logger = logger
    end

    def call
      return if @agent_run.verification_result.present? && @agent_run.verification_result["status"].present?
      return unless @agent_run.project.verification_enabled?
      return if @repo_path.blank?

      payload = recorded_result || @fallback_result.presence || missing_result
      persisted = normalize(payload)
      @agent_run.update!(verification_result: persisted)
      persisted
    ensure
      cleanup_transient_files
    end

    private

    def recorded_result
      return unless File.exist?(result_path)

      JSON.parse(File.read(result_path))
    rescue JSON::ParserError => e
      invalid_json_result(e)
    end

    def normalize(payload)
      hash = payload.is_a?(Hash) ? payload.deep_stringify_keys : {}
      status = hash["status"].to_s
      status = "failed" unless status.in?(VALID_STATUSES)

      {
        "status" => status,
        "summary" => hash["summary"].presence || default_summary_for(status),
        "reason" => hash["reason"].presence,
        "details" => hash["details"].presence,
        "app_url" => hash["app_url"].presence,
        "start_command" => hash["start_command"].presence,
        "used_browser_tools" => hash["used_browser_tools"] == true,
        "browser_steps" => normalize_string_array(hash["browser_steps"]),
        "changed_surfaces" => normalize_string_array(hash["changed_surfaces"]),
        "artifacts" => normalize_artifacts(hash["artifacts"]),
        "app_log_tail" => app_log_tail,
        "recorded_at" => Time.current.iso8601
      }.compact
    end

    def normalize_string_array(value)
      Array(value).filter_map do |entry|
        text = entry.to_s.strip
        text if text.present?
      end.first(20)
    end

    def normalize_artifacts(value)
      Array(value).filter_map do |artifact|
        next unless artifact.is_a?(Hash)

        normalized = artifact.deep_stringify_keys.slice("kind", "path", "url", "note")
        normalized.compact!
        normalized.presence
      end.first(10)
    end

    def invalid_json_result(error)
      {
        "status" => "failed",
        "reason" => "invalid_verification_result_json",
        "summary" => "Verification result file was present but invalid JSON.",
        "details" => error.message
      }
    end

    def missing_result
      {
        "status" => "not_run",
        "reason" => "verification_result_missing",
        "summary" => "Verification was enabled, but no verification result was recorded."
      }
    end

    def default_summary_for(status)
      {
        "passed" => "Interactive verification passed.",
        "failed" => "Interactive verification failed.",
        "skipped" => "Interactive verification was skipped.",
        "not_run" => "Interactive verification did not run."
      }.fetch(status)
    end

    def app_log_tail
      return if !File.exist?(app_log_path) || File.directory?(app_log_path)

      read_log_tail(app_log_path, max_lines: LOG_TAIL_LINES)
    rescue StandardError => e
      @logger.warn(
        message: "agent_runs.verification_result.log_tail_failed",
        agent_run_id: @agent_run.id,
        error: e.message
      )
      nil
    end

    def read_log_tail(path, max_lines:)
      File.open(path, "rb") do |file|
        buffer = +""
        position = file.size

        while position.positive? && buffer.count("\n") <= max_lines && buffer.bytesize < LOG_TAIL_MAX_BYTES
          read_size = [ LOG_TAIL_CHUNK_BYTES, position ].min
          position -= read_size
          file.seek(position)
          buffer.prepend(file.read(read_size))
        end

        normalize_log_tail(buffer, max_lines:)
      end
    end

    def normalize_log_tail(content, max_lines:)
      content = content.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "")
      lines = content.lines.last(max_lines)
      lines.join.presence
    end

    def cleanup_transient_files
      [ result_path, app_log_path, app_pid_path ].each do |path|
        File.delete(path) if File.exist?(path) && !File.directory?(path)
      rescue StandardError => e
        @logger.warn(
          message: "agent_runs.verification_result.cleanup_failed",
          agent_run_id: @agent_run.id,
          path: path,
          error: e.message
        )
      end
    end

    def result_path
      File.join(@repo_path, AgentRuns::VerificationPrompt::RESULT_PATH)
    end

    def app_log_path
      File.join(@repo_path, AgentRuns::VerificationPrompt::APP_LOG_PATH)
    end

    def app_pid_path
      File.join(@repo_path, AgentRuns::VerificationPrompt::APP_PID_PATH)
    end
  end
end
