# frozen_string_literal: true

module CloseoutVerifications
  # Reviewed execution allowance, independent of semantic acceptance.
  # @spec STAGED-CLOSEOUT-ADOPTION-015
  class RetryPolicy
    MAX_ATTEMPTS = 3
    BACKOFF = 1.minute
    State = Data.define(:generation, :reason, :attempts, :max_attempts, :eligible_after)

    def self.limit(raw)
      return unless raw.is_a?(Hash)

      value = raw.stringify_keys.fetch("max_attempts", 1)
      parsed = Integer(value.to_s, 10)
      parsed if (1..MAX_ATTEMPTS).cover?(parsed)
    rescue ArgumentError, TypeError
      nil
    end

    def self.for(mapping:, run:, current_result: nil)
      maximum = limit(mapping.retry_policy)
      return State.new(nil, "retry_policy_invalid", 0, nil, nil) unless maximum
      return State.new(0, nil, 0, maximum, nil) unless run

      attempts = run.closeout_verification_generation + 1
      reason = if run.status.in?(%w[queued running])
        "verification_in_progress"
      elsif run.status == "cancelled"
        "retry_cancelled"
      elsif run.status == "completed" && (current_result.nil? ? Evidence.current_for_run?(run) : current_result)
        "result_current"
      elsif attempts >= maximum
        "retry_exhausted"
      elsif run.completed_at.nil? || run.completed_at > Time.current
        "completion_time_unavailable"
      elsif run.verification_result.dig("closeout_verification", "technical_evidence", "cleanup", "completed") == false
        "cleanup_required"
      end
      return State.new(nil, reason, attempts, maximum, nil) if reason

      eligible_after = run.completed_at + BACKOFF
      return State.new(nil, "retry_backoff", attempts, maximum, eligible_after) if eligible_after > Time.current

      State.new(attempts, nil, attempts, maximum, eligible_after)
    end
  end
end
