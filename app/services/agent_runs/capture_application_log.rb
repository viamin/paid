# frozen_string_literal: true

module AgentRuns
  # Persists one redacted, bounded log observation while its agent can act on it.
  # @spec APP-DIAGNOSTICS-004
  class CaptureApplicationLog
    MAX_LOG_BYTES = 32 * 1024

    class TooLargeError < StandardError; end

    def self.call(...)
      new(...).call
    end

    def initialize(agent_run:, content:)
      @agent_run = agent_run
      @content = content.to_s
    end

    def call
      raise TooLargeError, "application log exceeds #{MAX_LOG_BYTES} bytes" if @content.bytesize > MAX_LOG_BYTES

      @agent_run.update!(verification_result: verification_result)
    end

    private

    def verification_result
      @agent_run.verification_result.to_h.merge(
        "app_log_tail" => redacted_content,
        "app_log_recorded_at" => Time.current.iso8601
      )
    end

    def redacted_content
      content = @content.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "")
      AgentRuns::Research::SecretGuard.redact_text(content)
    end
  end
end
