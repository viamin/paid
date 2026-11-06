# frozen_string_literal: true

module Automation
  # Single write boundary for bounded delivery authorization. Every caller
  # supplies explicit evidence; reserved product/release actions fail closed.
  # @spec BOUNDED-PHASE-AUTHORIZATION-010 @spec BOUNDED-PHASE-AUTHORIZATION-011
  class AuthorizeBoundedAction
    class Error < StandardError; end
    class PermissionDenied < Error; end
    class ProhibitedAction < Error; end
    class InvalidScope < Error; end
    class InvalidEvidence < Error; end

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
      ensure_evidence!

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

      if BoundedDelegatedAction::RESERVED_ACTIONS.include?(action)
        raise ProhibitedAction, "#{action} is a reserved decision and cannot be delegated"
      end

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

    def ensure_evidence!
      raise InvalidEvidence, "Evidence must be an object." unless evidence.is_a?(Hash)

      ensure_intent_digest!
      ensure_acceptance_refs!
    end

    def ensure_intent_digest!
      digest = evidence_value("intent_digest")
      return if digest.is_a?(String) && digest.match?(BoundedDelegatedAction::INTENT_DIGEST_FORMAT)

      raise InvalidEvidence, "Evidence must include intent_digest as a sha256:<64 hex characters> digest."
    end

    def ensure_acceptance_refs!
      acceptance_references = evidence_value("acceptance_refs")
      return if acceptance_references.is_a?(Array) && acceptance_references.any?(&:present?)

      raise InvalidEvidence, "Evidence must include acceptance_refs."
    end

    def evidence_value(key)
      evidence[key] || evidence[key.to_sym]
    end
  end
end
