# frozen_string_literal: true

module FeatureIntents
  # Continuation of a pinned repository-artifact reconciliation page.
  # @spec DESIGN-RECONCILIATION-004
  class ReconcileDesignArtifactsPageJob < ReconcileDesignArtifactsJob
    good_job_control_concurrency_with(
      enqueue_limit: 2,
      perform_limit: 1,
      key: -> { "design_artifact_reconciliation_#{arguments.first}_" }
    )
  end
end
