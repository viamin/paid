# frozen_string_literal: true

module AgentPlanningHolds
  # Releases only direct agent holds whose recorded, mechanical condition is
  # satisfied. Closure resolves an obsolete Inbox request without granting
  # authority over the label; reopening reassesses the same durable receipt.
  # @spec CONFIDENCE-DELIVERY-018 CONFIDENCE-DELIVERY-019
  class Reconcile
    Result = Data.define(:released, :reason) do
      def released? = released
    end

    def self.call(...) = new(...).call

    def initialize(hold:)
      @hold = hold
    end

    def call
      attach_synced_issue!
      return Result.new(released: false, reason: "Planning hold issue has not synchronized yet.") unless hold.issue
      return retire_closed_issue if hold.issue.github_state == "closed"

      reopened = closed_resolution_pending_reassessment?
      record_reopen! if reopened
      return resolve_absent_label unless hold.issue.has_label?(hold.label)
      RequestReview.call(hold:) if reopened
      return request_operator_review unless hold.supported_release_condition?
      return Result.new(released: false, reason: "Planning hold needs operator reconciliation.") unless hold.releasable?
      return Result.new(released: false, reason: "Planning hold release condition is not satisfied.") unless condition_satisfied?

      remove_and_read_back!
      hold.update!(status: "released", reconciled_at: Time.current, last_error: nil)
      resolve_notification(action: "released")
      Result.new(released: true, reason: nil)
    rescue GithubClient::Error => error
      hold.update!(status: "reconciliation_failed", last_error: error.message)
      Result.new(released: false, reason: error.message)
    end

    private

    attr_reader :hold

    def condition_satisfied?
      case hold.release_condition["kind"]
      when "agent_run_finished"
        return false unless hold.agent_run_id.to_s == hold.release_condition["agent_run_id"].to_s

        hold.agent_run&.finished?
      when "dependencies_resolved" then hold.issue.ready_to_work?
      when "issue_closed"
        project.issues.find_by(github_number: hold.release_condition["issue_number"])&.github_state == "closed"
      else false
      end
    end

    def attach_synced_issue!
      if hold.issue
        hold.issue.reload
        return
      end

      issue = project.issues.find_by(github_number: hold.remote_issue_number)
      hold.update!(issue:) if issue
    end

    def remove_and_read_back!
      remove_label!
      read_back!
    end

    def remove_label!
      client.remove_label_from_issue(project.full_name, hold.issue.github_number, hold.label)
    rescue GithubClient::NotFoundError
      # The remote label is already absent, so continue with authoritative read-back.
    end

    def read_back!
      remote = client.issue(project.full_name, hold.issue.github_number)
      labels = Array(remote.labels).map { |label| label.respond_to?(:name) ? label.name : label.to_s }
      raise GithubClient::Error, "planning hold remained after GitHub write" if labels.include?(hold.label)

      Issues::UpsertFromGithub.call(project:, github_issue: remote)
    end

    def request_operator_review
      hold.update!(status: "needs_review", last_error: "Unsupported planning hold release condition.")
      RequestReview.call(hold:)
      Result.new(released: false, reason: "Planning hold release condition requires operator review.")
    end

    def retire_closed_issue
      hold.update!(
        status: "needs_review",
        reconciled_at: Time.current,
        last_error: nil,
        evidence: evidence_with_closed_resolution
      ) unless closed_resolution_recorded?
      resolve_notification(action: "closed_issue")
      Result.new(released: false, reason: "Planning hold is obsolete while its issue is closed.")
    end

    def resolve_absent_label
      resolve_notification(action: "label_absent")
      Result.new(released: false, reason: "Planning hold label is absent.")
    end

    def closed_resolution_recorded?
      hold.evidence.dig("closure_resolution", "reopened_at").nil? && hold.evidence.key?("closure_resolution")
    end

    def closed_resolution_pending_reassessment?
      hold.evidence.key?("closure_resolution") && hold.evidence.dig("closure_resolution", "reopened_at").nil?
    end

    def evidence_with_closed_resolution
      prior_resolution = {
        "closed_at" => Time.current.iso8601,
        "status" => hold.status,
        "last_error" => hold.last_error
      }.compact
      evidence = hold.evidence.deep_dup
      evidence["closure_resolutions"] = Array(evidence["closure_resolutions"]) + [ prior_resolution ]
      evidence["closure_resolution"] = prior_resolution.merge("reopened_at" => nil)
      evidence
    end

    def record_reopen!
      evidence = hold.evidence.deep_dup
      evidence["closure_resolution"] = evidence.fetch("closure_resolution").merge("reopened_at" => Time.current.iso8601)
      prior_status = evidence.dig("closure_resolution", "status") || hold.status
      hold.update!(status: prior_status, evidence:)
    end

    def resolve_notification(action:)
      notifications.find_each do |notification|
        next if notification.resolved_at.present?

        notification.update!(
          resolved_at: Time.current,
          metadata: notification.metadata.merge(
            "resolution_history" => Array(notification.metadata["resolution_history"]) + [
              { "action" => action, "at" => Time.current.iso8601 }
            ]
          )
        )
      end
    end

    def notifications
      scope = Notification.where(account: project.account, source: "agent_planning_hold_reconciliation")
      issue_notifications = scope.where(subject: hold.issue)
      return issue_notifications unless hold.agent_run

      issue_notifications.or(scope.where(subject: hold.agent_run))
    end

    def client = project.client
    def project = hold.project
  end
end
