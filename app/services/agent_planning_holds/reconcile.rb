# frozen_string_literal: true

module AgentPlanningHolds
  # Releases only direct agent holds whose recorded, mechanical condition is
  # satisfied. Conditions that need design judgment remain actionable Inbox
  # work; neither a closed parent issue nor the bot identity authorizes them.
  # @spec CONFIDENCE-DELIVERY-018
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
      return request_operator_review unless hold.supported_release_condition?
      return Result.new(released: false, reason: "Planning hold needs operator reconciliation.") unless hold.releasable?
      return Result.new(released: false, reason: "Planning hold release condition is not satisfied.") unless condition_satisfied?

      remove_and_read_back!
      hold.update!(status: "released", reconciled_at: Time.current, last_error: nil)
      resolve_notification
      Result.new(released: true, reason: nil)
    rescue GithubClient::Error => error
      hold.update!(status: "reconciliation_failed", last_error: error.message)
      Result.new(released: false, reason: error.message)
    end

    private

    attr_reader :hold

    def condition_satisfied?
      case hold.release_condition["kind"]
      when "dependencies_resolved" then hold.issue.ready_to_work?
      when "issue_closed"
        project.issues.find_by(github_number: hold.release_condition["issue_number"])&.github_state == "closed"
      else false
      end
    end

    def attach_synced_issue!
      return if hold.issue

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

    def resolve_notification
      Notification.where(account: project.account, source: "agent_planning_hold_reconciliation", subject: hold.issue)
        .update_all(resolved_at: Time.current, updated_at: Time.current)
    end

    def client = project.client
    def project = hold.project
  end
end
