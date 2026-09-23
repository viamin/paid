# frozen_string_literal: true

module AppleVerificationAttempts
  # Re-invokes AgentRun#complete! for a run whose completion was withheld at
  # the completion-verification gate, once the gate is satisfied (a succeeded
  # attempt or an active waiver). The workflow that originally invoked
  # completion has already returned success, so without this re-invocation a
  # withheld run could never report success.
  # @spec APPLE-ATTEMPT-013
  class CompleteWithheldRun
    def self.call(agent_run:)
      new(agent_run:).call
    end

    def initialize(agent_run:)
      @agent_run = agent_run
    end

    def call
      return false unless @agent_run.reload.status == "running"

      payload = @agent_run.external_metadata[AgentRun::COMPLETION_VERIFICATION_WITHHELD_METADATA_KEY]
      return false if payload.blank?

      # Only complete when the gate no longer enforces: while pending the run
      # stays withheld, and a blocked gate must keep withholding rather than
      # surface as a completion failure through this path. The gate binds to
      # the commit the original workflow shipped so a verification of a
      # different commit cannot leak forward to satisfy completion.
      decision = GateEnforcement.evaluate(
        agent_run: @agent_run,
        gate: "completion_verification",
        result_commit: payload["result_commit"]
      )
      return false if decision.enforcing?

      @agent_run.complete!(**completion_attributes(payload))
    end

    private

    def completion_attributes(payload)
      {
        result_commit: payload["result_commit"],
        pr_url: payload["pr_url"],
        pr_number: payload["pr_number"],
        issue_url: payload["issue_url"],
        issue_number: payload["issue_number"]
      }
    end
  end
end
