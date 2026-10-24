# frozen_string_literal: true

module Issues
  # Admits a bounded closeout assessment without authorizing implementation.
  # The persisted continuation mode is consumed by the workflow, rather than
  # inferred from operator prose.
  # @spec PARTIAL-CLOSEOUT-027
  class RequestAcceptanceAudit
    REASON = "Run a report-only acceptance audit against the current closeout evidence and approved intent."

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
        continuation_mode: "acceptance_audit"
      )
    end

    private

    attr_reader :actor, :issue
  end
end
