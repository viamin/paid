# frozen_string_literal: true

module AgentPlanningHolds
  # Releases only direct agent holds whose recorded, mechanical condition is
  # satisfied. Conditions that need design judgment remain actionable Inbox
  # work; neither a closed parent issue nor the bot identity authorizes them.
  #
  # A closed issue never needs release into auto-pick, so once the hold's own
  # issue is closed this short-circuits to {close_without_release}: the stale
  # Inbox notification is resolved, but the hold's status, the GitHub label,
  # and any operator/design judgment it still requires are left untouched for
  # audit. Reopening re-runs this same call (see Issue's reopen hook) so a
  # still-unresolved hold surfaces a fresh request rather than staying
  # permanently suppressed.
  # @spec CONFIDENCE-DELIVERY-018
  # @spec CONFIDENCE-DELIVERY-019
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
      return close_without_release if hold.issue.github_state == "closed" && hold.status != "released"
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

    # Retires the stale Inbox entry without claiming a release: the status,
    # evidence, and GitHub label stay exactly as an operator left them so a
    # later reopen (CONFIDENCE-DELIVERY-019) can recompute the real blocker.
    def close_without_release
      resolve_notification
      Result.new(released: false, reason: "Planning hold issue is closed; retired without release.")
    end

    # A notification published before the hold's issue synchronized locally
    # is keyed on the agent run instead (see RequestReview); check both so a
    # closure doesn't leave that earlier notification stale.
    def resolve_notification
      subjects = [ hold.issue, hold.agent_run ].compact
      return if subjects.empty?

      Notification.where(account: project.account, source: RequestReview::SOURCE, subject: subjects, resolved_at: nil)
        .find_each do |notification|
          Notifications::Resolve.call(account: notification.account, source: notification.source,
            subject: notification.subject, user: notification.user)
        end
    end

    def client = project.client
    def project = hold.project
  end
end
