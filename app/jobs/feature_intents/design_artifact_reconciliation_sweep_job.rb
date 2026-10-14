# frozen_string_literal: true

module FeatureIntents
  # Bounded daily backstop for already-open design pull requests that did not
  # receive a fresh webhook after this reconciliation capability was enabled.
  # @spec DESIGN-RECONCILIATION-001
  class DesignArtifactReconciliationSweepJob < ApplicationJob
    BATCH_SIZE = 100

    queue_as :maintenance

    def perform(after_id: nil)
      scope = FeatureIntentDesignPr.where(merged_at: nil).order(:id)
      scope = scope.where("feature_intent_design_prs.id > ?", after_id) if after_id
      design_prs = scope.limit(BATCH_SIZE).includes(feature_intent: :project)
      design_prs.each { |design_pr| ReconcileDesignArtifactsJob.perform_later(design_pr.feature_intent.project_id, design_pr.pull_request_number) }
      self.class.perform_later(after_id: design_prs.last.id) if design_prs.size == BATCH_SIZE
    end
  end
end
