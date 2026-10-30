# frozen_string_literal: true

module AgentPlanningHolds
  # Keeps unknown ownership and unsupported release contracts visible until an
  # operator decides whether the shared GitHub label may be removed.
  # @spec CONFIDENCE-DELIVERY-018
  class RequestReview
    def self.call(hold:)
      Notification.create_or_find_by!(
        account: hold.account,
        source: "agent_planning_hold_reconciliation",
        subject: hold.issue || hold.agent_run
      ) do |notification|
        notification.severity = :error
        notification.blocking = true
        notification.nav_section = "projects"
        notification.title = "Planning hold needs reconciliation"
        notification.description = "Planning on issue ##{hold.remote_issue_number} requires operator reconciliation."
        notification.metadata = metadata(hold)
      end
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
