# frozen_string_literal: true

module PartialCloseouts
  # Reads the latest completed report-only acceptance audit (#4759) for an
  # issue and reports whether its persisted closure disposition is still
  # current. Deterministic and read-only: it never calls `agent_harness`
  # itself, it only re-validates a previously recorded assessment against
  # live evidence via {SourceClosureDisposition.for}, so callers outside the
  # audit workflow (the 60s sync, one-off reconciliation) can reuse a
  # genuine, evidence-bound closure verdict instead of judging PR bookkeeping
  # directly (#4772).
  # @spec PARTIAL-CLOSEOUT-038
  class SourceClosureEvidence
    def self.current_close?(issue) = new(issue).current_close?

    def initialize(issue)
      @issue = issue
    end

    def current_close?
      return false unless audit_run

      SourceClosureDisposition.for(audit_run).fetch("disposition") == SourceClosureDisposition::CLOSE
    end

    private

    attr_reader :issue

    def audit_run
      AgentRun.joins(:continuation_request)
        .where(issue: issue, goal: "analyze_issue", status: "completed")
        .where("issue_continuation_requests.evidence->>'continuation_mode' = ?", "acceptance_audit")
        .order(completed_at: :desc)
        .first
    end
  end
end
