# frozen_string_literal: true

module AgentRuns
  # Persists one redacted, bounded log observation while its agent can act on it.
  # @spec OBSERVABILITY-APP-DIAGNOSTICS-004
  class CaptureApplicationLog
    MAX_LOG_BYTES = ApplicationLog::MAX_BYTES

    class TooLargeError < StandardError; end

    def self.call(...)
      new(...).call
    end

    def initialize(agent_run:, content:)
      @agent_run = agent_run
      @content = content.to_s
    end

    def call
      return if @content.strip.empty?

      raise TooLargeError, "application log exceeds #{MAX_LOG_BYTES} bytes" if @content.bytesize > MAX_LOG_BYTES

      @agent_run.with_lock do
        return unless @agent_run.active? && @agent_run.verification_applicable?

        @agent_run.update!(verification_result: verification_result)
      end
    end

    private

    def verification_result
      @agent_run.verification_result.to_h.merge(
        "app_log_tail" => application_log.content,
        "app_log_recorded_at" => Time.current.iso8601,
        "app_log_truncated" => application_log.truncated
      )
    end

    def application_log
      @application_log ||= ApplicationLog.redact_and_bound(@content, agent_run: @agent_run)
    end
  end
end
