# frozen_string_literal: true

module Issues
  # @spec PARTIAL-CLOSEOUT-030
  class RequestTechnicalPrerequisiteValidation
    REASON = "Collect isolated execution evidence for the current technical prerequisite."

    def self.call(...) = new(...).call

    def initialize(issue:, actor:)
      @issue = issue
      @actor = actor
    end

    def call
      RequestContinuation.call(
        issue: issue, actor: actor, reason: REASON, goal: "analyze_issue",
        continuation_mode: "technical_prerequisite_validation"
      )
    end

    private

    attr_reader :actor, :issue
  end
end
