# frozen_string_literal: true

module DesignAmendments
  # Records the merged repository revision of an approved design amendment:
  # the new baseline. Advances the feature's approved design revision,
  # returns the feature to `released`, and evaluates revision impact across
  # the feature's branches. Atomic — an evaluation failure leaves the
  # amendment unmerged and the feature revising.
  # @spec INTENT-AMENDMENT-004
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
      # open. A review failure fails closed inside EvaluateImpact, so
      # nothing here depends on catching it.
      review = EvaluateImpact.review_for(amendment)

      # requires_new so a write failure rolls back exactly this unit
      # (savepoint) instead of poisoning a caller's transaction.
      DesignAmendment.transaction(requires_new: true) do
        amendment.update!(
          status: "merged",
          amended_revision: merged_revision,
          merged_at: Time.current
        )
        record_new_baseline
        EvaluateImpact.call(amendment: amendment, review: review)
      end
      amendment
    end

    private

    attr_reader :amendment, :merged_revision

    def record_new_baseline
      feature = amendment.feature_intent
      feature.update!(
        approved_design_revision: merged_revision,
        approved_revision_recorded_at: Time.current
      )
      feature.release!
    end
  end
end
