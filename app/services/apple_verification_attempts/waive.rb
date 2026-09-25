# frozen_string_literal: true

module AppleVerificationAttempts
  # Creates a one-attempt waiver without changing its workflow binding.
  # @spec APPLE-VERIFY-006
  class Waive
    def self.call(attempt:, actor:, attributes:)
      new(attempt:, actor:, attributes:).call
    end

    def initialize(attempt:, actor:, attributes:)
      @attempt = attempt
      @actor = actor
      @attributes = attributes
    end

    def call
      raise ArgumentError, "only a failed attempt can be waived" unless @attempt.failed?

      waiver = @attempt.apple_verification_waivers.create!(
        account: @attempt.account,
        project: @attempt.project,
        apple_verification_workflow_revision: @attempt.apple_verification_workflow_revision,
        created_by: @actor,
        source_digest: @attempt.source_digest,
        lifecycle_gate: @attempt.lifecycle_gate,
        **@attributes
      )
      complete_withheld_run
      waiver
    end

    private

    # An active waiver can satisfy the completion gate, so finish a completion
    # that was withheld on this attempt's agent run.
    # @spec APPLE-ATTEMPT-013
    def complete_withheld_run
      return unless @attempt.agent_run

      CompleteWithheldRun.call(agent_run: @attempt.agent_run)
    end
  end
end
