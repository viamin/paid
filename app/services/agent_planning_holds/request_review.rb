# frozen_string_literal: true

module AgentPlanningHolds
  # Keeps unknown ownership and unsupported release contracts visible until an
  # operator decides whether the shared GitHub label may be removed.
  # @spec CONFIDENCE-DELIVERY-018
  class RequestReview
    def self.call(hold:)
      hold.with_lock do
        subject = hold.issue || hold.agent_run
        notification = Notification.find_by(
          account: hold.account,
          source: "agent_planning_hold_reconciliation",
          subject:
        )
        return notification if notification&.active?

        return create_notification(hold:, subject:) unless notification

        notification.update!(
          resolved_at: nil,
          dismissed_at: nil,
          metadata: metadata(hold).merge("resolution_history" => resolution_history(notification, "reopened"))
        )
        notification
      end
    end

    def self.create_notification(hold:, subject:)
      Notification.create!(
        account: hold.account,
        source: "agent_planning_hold_reconciliation",
        subject:,
        severity: :error,
        blocking: true,
        nav_section: "projects",
        title: "Planning hold needs reconciliation",
        description: "Planning on issue ##{hold.remote_issue_number} requires operator reconciliation.",
        metadata: metadata(hold)
      )
    end
    private_class_method :create_notification

    def self.metadata(hold)
      {
        "issue_number" => hold.remote_issue_number,
        "agent_run_id" => hold.agent_run_id,
        "hold_id" => hold.id,
        "recommended_action" => "Review the hold owner and release condition before removing the label."
      }.compact
    end
    private_class_method :metadata

    def self.resolution_history(notification, action)
      Array(notification.metadata["resolution_history"]) + [{ "action" => action, "at" => Time.current.iso8601 }]
    end
    private_class_method :resolution_history
  end
end
