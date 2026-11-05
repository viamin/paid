# frozen_string_literal: true

module Automation
  # Single write boundary for bounded delivery authorization. Every caller
  # supplies explicit evidence; reserved product/release actions fail closed.
  # @spec BOUNDED-DELEGATED-ACTION-001 @spec BOUNDED-DELEGATED-ACTION-002
  class AuthorizeBoundedAction
    class Error < StandardError; end
    class PermissionDenied < Error; end
    class ProhibitedAction < Error; end
    class InvalidScope < Error; end

    def self.call(...)
      new(...).call
    end

    def initialize(project:, issue:, user:, action:, evidence:, expires_at: 24.hours.from_now)
      @project = project
      @issue = issue
      @user = user
      @action = action.to_s
      @evidence = evidence
      @expires_at = expires_at
    end

    def call
      ensure_action_supported!
      ensure_scope!
      ensure_permission!

      project.transaction do
        authorization = project.bounded_delegated_actions.create!(
          account: project.account,
          issue:,
          created_by: user,
          action:,
          evidence: evidence.deep_stringify_keys,
          expires_at:
        )
        Audit::RecordEvent.call(
          action: "bounded_action.authorized",
          actor: user,
          subject: authorization,
          metadata: { "action" => action, "evidence" => authorization.evidence }
        )
        authorization
      end
    end

    private

    attr_reader :project, :issue, :user, :action, :evidence, :expires_at

    def ensure_action_supported!
      return if BoundedDelegatedAction::ACTIONS.include?(action)

      raise ProhibitedAction, "#{action.presence || "unknown"} is not a delegable delivery action"
    end

    def ensure_scope!
      return if issue && issue.project_id == project.id && issue.project.account_id == project.account_id

      raise InvalidScope, "The work item must belong to the selected project and account."
    end

    def ensure_permission!
      return if ProjectPolicy.new(user, project).delegate_bounded_action?(action)

      raise PermissionDenied, "You do not have permission to delegate #{action} for this project."
    end
  end
end
