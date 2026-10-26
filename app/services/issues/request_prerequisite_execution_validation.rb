# frozen_string_literal: true

module Issues
  # Admits one isolated execution-environment validation for an unresolved
  # prerequisite. It deliberately reuses continuation admission: this is
  # evidence collection, never an authority to implement or close the issue.
  # @spec PREREQUISITE-EXECUTION-001
  class RequestPrerequisiteExecutionValidation
    REASON = "Collect isolated execution evidence for the current prerequisite and retain its result and cleanup record."

    def self.call(...) = new(...).call

    def initialize(issue:, actor:)
      @issue = issue
      @actor = actor
    end

    def call
      RequestContinuation.call(
        issue:,
        actor:,
        reason: REASON,
        goal: "analyze_issue",
        continuation_mode: "prerequisite_execution_validation"
      )
    end

    private

    attr_reader :actor, :issue
  end
end
