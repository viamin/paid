# frozen_string_literal: true

module Issues
  # Admits a bounded closeout assessment without authorizing implementation.
  # The persisted continuation mode is consumed by the workflow, rather than
  # inferred from operator prose.
  # @spec PARTIAL-CLOSEOUT-027
  class RequestAcceptanceAudit
    REASON = "Run a report-only acceptance audit against the current closeout evidence and approved intent."

    def self.call(...) = new(...).call

    def initialize(issue:, actor:, origin: :operator)
      @issue = issue
      @actor = actor
      @origin = origin
    end

    def call
      RequestContinuation.call(
        issue:,
        actor:,
        origin:,
        reason: REASON,
        goal: "analyze_issue",
        continuation_mode: "acceptance_audit"
      )
    end

    private

    attr_reader :actor, :issue, :origin
  end
end
