# frozen_string_literal: true

module AgentPlanningHolds
  # Keeps unknown ownership and unsupported release contracts visible until an
  # operator decides whether the shared GitHub label may be removed. Publishes
  # (rather than find-or-creates) so a notification already resolved as
  # obsolete by {Reconcile} on issue closure comes back as a fresh actionable
  # entry if the issue later reopens with the hold still unresolved.
  # @spec CONFIDENCE-DELIVERY-018
  # @spec CONFIDENCE-DELIVERY-019
  class RequestReview
    SOURCE = "agent_planning_hold_reconciliation"

    def self.call(hold:)
      Notifications::Publish.call(
        account: hold.account,
        source: SOURCE,
        subject: hold.issue || hold.agent_run,
        severity: :error,
        blocking: true,
        nav_section: "projects",
        title: "Planning hold needs reconciliation",
        description: "Planning on issue ##{hold.remote_issue_number} requires operator reconciliation.",
        metadata: metadata(hold)
      )
    end

    def self.metadata(hold)
      {
        "issue_number" => hold.remote_issue_number,
        "agent_run_id" => hold.agent_run_id,
        "hold_id" => hold.id,
        "recommended_action" => "Review the hold owner and release condition before removing the label."
      }.compact
    end
    private_class_method :metadata
  end
end
