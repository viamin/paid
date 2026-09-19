# frozen_string_literal: true

module Activities
  # @spec APPLE-VERIFY-003
  class StartAppleVerificationAttemptActivity < BaseActivity
    activity_name "StartAppleVerificationAttempt"

    def execute(input)
      attempt = AppleVerificationAttempt.find(input.fetch(:attempt_id))
      attempt.with_lock do
        attempt.reload
        return result(attempt) unless attempt.queued?

        attempt.update!(state: "running")
        result(attempt)
      end
    end

    private

    def result(attempt)
      { status: attempt.state.to_sym, attempt_id: attempt.id }
    end
  end
end
