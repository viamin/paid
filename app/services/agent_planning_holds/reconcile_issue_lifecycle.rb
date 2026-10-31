# frozen_string_literal: true

module AgentPlanningHolds
  # Reconciles closure and reopen lifecycle transitions from an authoritative
  # GitHub issue sync without widening a normal sync into label release work.
  # @spec CONFIDENCE-DELIVERY-019
  class ReconcileIssueLifecycle
    def self.call(...) = new(...).call

    def initialize(issue:)
      @issue = issue
    end

    def call
      holds.find_each do |hold|
        attach_issue!(hold)
        AgentPlanningHolds::Reconcile.call(hold:) if issue.github_state == "closed" || reopening?(hold)
      end
    end

    private

    attr_reader :issue

    def holds
      AgentPlanningHold.where(
        project: issue.project,
        remote_issue_number: issue.github_number,
        status: %w[held needs_review reconciliation_failed]
      )
    end

    def attach_issue!(hold)
      hold.update!(issue:) unless hold.issue_id == issue.id
    end

    def reopening?(hold)
      hold.evidence.dig("closure_resolution", "reopened_at").nil? && hold.evidence.key?("closure_resolution")
    end
  end
end
