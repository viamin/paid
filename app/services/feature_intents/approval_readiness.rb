# frozen_string_literal: true

module FeatureIntents
  # Readiness gate for the Inbox "Mark approved" action (RDR-066 "Discovery
  # and approval readiness"). Deterministic state checks own the structural
  # blockers (open questions, unconfirmed inferred decisions, stale design
  # PR heads); the acceptance-criteria clarity judgment is delegated to AI
  # (ZFC) via CriteriaClarityReview and fails closed. This is the single
  # place that answers "is this feature ready to approve" so the Inbox entry
  # and the approval action never disagree.
  # @spec FEATURE-APPROVAL-011
  class ApprovalReadiness
    Blocker = Data.define(:code, :message)
    Result = Data.define(:ready, :blockers) do
      def ready? = ready
    end

    def self.call(...)
      new(...).call
    end

    def initialize(feature_intent:)
      @feature_intent = feature_intent
    end

    def call
      blockers = [
        not_approvable_status_blocker,
        unresolved_question_blocker,
        unconfirmed_inferred_decision_blocker,
        stale_design_pr_blocker,
        vague_criteria_blocker
      ].compact

      Result.new(ready: blockers.empty?, blockers: blockers)
    end

    private

    attr_reader :feature_intent

    # Mirrors `FeatureIntent#record_approval!`'s status guard so the Inbox
    # entry, the detail view, and `MarkApproved` agree about which statuses
    # accept an approval. Without this, a `discovering` feature intent that
    # happens to pass every other check (e.g. clear criteria, no open
    # decisions) would surface an enabled "Mark approved" button that 500s
    # on click, because `discovering` is in `FEATURE_DECISION_STATUSES` (so
    # it appears in the inbox) but not in `APPROVABLE_STATUSES`.
    def not_approvable_status_blocker
      return if feature_intent.status.in?(FeatureIntent::APPROVABLE_STATUSES)

      Blocker.new(
        code: "not_approvable_status",
        message: "Feature is in '#{feature_intent.status}' state and cannot be approved yet."
      )
    end

    # These filters walk the loaded association arrays instead of re-scoping
    # with `.where` (which always issues a fresh query) so the Inbox queue's
    # `includes(:feature_intent_decisions, :feature_intent_design_prs)`
    # preload is actually used — no N+1 per feature-decision entry per render.
    def unresolved_question_blocker
      count = feature_intent.feature_intent_decisions.count { |decision| decision.question? && decision.open? }
      return if count.zero?

      Blocker.new(code: "unresolved_questions", message: "#{count} clarifying #{"question".pluralize(count)} still open.")
    end

    def unconfirmed_inferred_decision_blocker
      count = feature_intent.feature_intent_decisions.count { |decision| decision.inferred_decision? && decision.open? }
      return if count.zero?

      Blocker.new(code: "unconfirmed_inferred_decisions", message: "#{count} inferred #{"decision".pluralize(count)} still need human confirmation.")
    end

    def stale_design_pr_blocker
      stale = feature_intent.feature_intent_design_prs.select { |design_pr| design_pr.required? && design_pr.stale? }
      return if stale.empty?

      numbers = stale.map { |design_pr| "##{design_pr.pull_request_number}" }.join(", ")
      Blocker.new(code: "stale_design_prs", message: "New commits landed on #{numbers} since the open decisions were last evaluated.")
    end

    # Reads the cached CriteriaClarityReview verdict (EvaluateCriteriaClarity
    # persists it) rather than calling the LLM inline — Inbox rendering must
    # stay a deterministic, fast read (AGD), not one LLM round-trip per
    # feature per page view. An unevaluated feature fails closed as blocked.
    def vague_criteria_blocker
      return if feature_intent.criteria_clarity_clear?

      Blocker.new(
        code: "vague_acceptance_criteria",
        message: feature_intent.criteria_clarity_explanation.presence || pending_message
      )
    end

    def pending_message
      "Acceptance criteria clarity has not been evaluated yet."
    end
  end
end
