# frozen_string_literal: true

module FeatureIntents
  # Bounded daily backstop for repository RDRs and open design pull requests
  # that did not receive a fresh webhook after reconciliation was enabled.
  # @spec DESIGN-RECONCILIATION-001
  class DesignArtifactReconciliationSweepJob < ApplicationJob
    BATCH_SIZE = 100

    queue_as :maintenance

    def perform(after_id: nil)
      scope = Project.order(:id)
      scope = scope.where("projects.id > ?", after_id) if after_id
      projects = scope.limit(BATCH_SIZE)
      projects.each { |project| ReconcileDesignArtifactsJob.perform_later(project.id) }
      self.class.perform_later(after_id: projects.last.id) if projects.size == BATCH_SIZE
    end
  end
end
