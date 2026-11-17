# frozen_string_literal: true

module DesignAmendments
  # Records the merged repository revision of an approved design amendment:
  # the new baseline. Advances the feature's approved design revision,
  # returns the feature to `released`, and evaluates revision impact across
  # the feature's branches. Confidence-driven routing follows the baseline
  # transaction so its durable remote-write intents survive GitHub failures.
  # @spec INTENT-AMENDMENT-004 @spec CONFIDENCE-DELIVERY-008
  class Complete
    def self.call(...)
      new(...).call
    end

    def initialize(amendment:, merged_revision:)
      @amendment = amendment
      @merged_revision = merged_revision
    end

    def call
      unless amendment.approval_current?(merged_revision: merged_revision)
        raise NotApprovedError, "amendment has no current human approval for #{merged_revision}"
      end

      # Run the LLM impact review before opening the transaction below, so
      # the network round trip doesn't hold the transaction's row locks
      # open. Approval-gated failures fail closed inside EvaluateImpact;
      # confidence-driven failures raise after this baseline is committed so
      # a retry cannot materialize speculative remote forward work.
      review = EvaluateImpact.review_for(amendment)

      # requires_new so a write failure rolls back exactly this unit
      # (savepoint) instead of poisoning a caller's transaction.
      DesignAmendment.transaction(requires_new: true) do
        record_merge
        EvaluateImpact.call(amendment: amendment, review: review) unless amendment.feature_intent.confidence_driven?
      end
      EvaluateImpact.call(amendment: amendment, review: review) if amendment.feature_intent.confidence_driven?
      amendment
    end

    private

    attr_reader :amendment, :merged_revision

    def record_merge
      amendment.update!(status: "merged", amended_revision: merged_revision, merged_at: Time.current)
      record_new_baseline
    end

    def record_new_baseline
      feature = amendment.feature_intent
      feature.update!(
        approved_design_revision: merged_revision,
        approved_revision_recorded_at: Time.current
      )
      feature.release!
      route_checkpoint_redecision
    end

    # @spec PROJECT-DELEGATION-002 — the new baseline is a design-revision
    # change, so every checkpoint settled against an earlier revision gets
    # one focused, deduplicated re-decision request instead of silently
    # carrying stale settled intent forward. The event changes only the
    # design revision: the shared drift handler carries each settlement's
    # acceptance revision through unchanged (keeping the comparison focused
    # on the design delta), and acceptance-only drift is routed by the same
    # handler where acceptance criteria are re-recorded.
    # (FeatureIntents::Release records the FIRST approved revision, not a
    # change of one, so it is not a drift event.)
    def route_checkpoint_redecision
      return if merged_revision.blank?

      ProjectDelegation::IntentCheckpoint::RouteDrift.on_design_change(
        feature_intent: amendment.feature_intent, design_revision: merged_revision
      )
    end
  end
end
