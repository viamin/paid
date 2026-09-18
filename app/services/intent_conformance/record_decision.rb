# frozen_string_literal: true

module IntentConformance
  # Records a human's resolution of a blocked intent-conformance verdict:
  # fix_pr, bounded_exception, or design_amendment. The decision is scoped to
  # the verdict's PR HEAD SHA, so a bounded_exception can never silently
  # cover a later commit (@spec INTENT-CONFORMANCE-005).
  #
  # @spec INTENT-CONFORMANCE-004
  class RecordDecision
    Result = Data.define(:success, :error, :decision) do
      def success? = success
    end

    def self.call(...) = new(...).call

    def initialize(verdict:, action:, reason:, actor:)
      @verdict = verdict
      @action = action
      @reason = reason
      @actor = actor
    end

    def call
      decision = IntentConformanceDecision.new(
        issue: verdict.issue,
        verdict: verdict,
        action: action,
        head_sha: verdict.pr_head_sha,
        reason: reason,
        actor: actor
      )

      return failure(decision) unless decision.save

      log_decision(decision)
      Result.new(success: true, error: nil, decision: decision)
    end

    private

    attr_reader :verdict, :action, :reason, :actor

    def failure(decision)
      Result.new(success: false, error: decision.errors.full_messages.to_sentence, decision: nil)
    end

    def log_decision(decision)
      Rails.logger.info(
        message: "intent_conformance.decision_recorded",
        component: "pr_review",
        issue_id: decision.issue_id,
        verdict_id: decision.verdict_id,
        pr_number: decision.issue.github_number,
        project_id: decision.issue.project_id,
        action: decision.action,
        head_sha: decision.head_sha,
        actor_user_id: decision.actor_id
      )
    end
  end
end
