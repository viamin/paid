# frozen_string_literal: true

module FeatureIntents
  # Reconciles the FeatureIntent whose design PR (RDR or LID Planning) was
  # closed unmerged on GitHub. Pulled out of the `pull_request` webhook
  # handler so the webhook thread can return within GitHub's delivery
  # timeout: a feature tree filed by `create_feature` commonly has 5-15
  # linked implementation issues, and `GithubClient#update_issue` retries
  # transient failures up to 3 times with exponential backoff, so a full
  # close blows past the ~10s webhook timeout otherwise.
  #
  # The job is idempotent. The cancellation write inside
  # `AttachFromAgentRun#detach_on_close!` lands first and is terminal in
  # the design-PR-closed sense (a subsequent GitHub reopen of the same PR
  # must not resurrect the feature); a retry that re-enters with the same
  # closed design PR sees the same FeatureIntent in a terminal status and
  # short-circuits. The per-issue closes are best-effort and guarded by
  # the issue's `github_state` predicate, so a redelivered webhook
  # converges to the same final state without duplicating close events.
  # @spec FEATURE-APPROVAL-017
  class CancelOnClosedDesignPrJob < ApplicationJob
    queue_as :default

    discard_on ActiveRecord::RecordNotFound

    def perform(project_id, pr_number:)
      project = Project.find_by(id: project_id)
      return unless project

      FeatureIntent
        .where(project_id: project.id)
        .joins(:feature_intent_design_prs)
        .where(feature_intent_design_prs: { pull_request_number: pr_number })
        .where.not(status: FeatureIntent::TERMINAL_STATUSES)
        .distinct
        .find_each do |feature_intent|
        FeatureIntents::AttachFromAgentRun.detach_on_close!(
          feature_intent: feature_intent,
          pull_request_number: pr_number,
          merged: false
        )
      end
    end
  end
end
