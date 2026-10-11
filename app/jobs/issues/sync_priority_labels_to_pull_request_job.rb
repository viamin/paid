# frozen_string_literal: true

module Issues
  # Bounded retry for a priority-label reconciliation whose GitHub write
  # failed transiently during an issue sync. The inline trigger in
  # Issues::UpsertFromGithub only fires when the issue's priority labels
  # change, and the issue's new labels are persisted before the
  # reconciliation runs — so once the inline attempt drops, no later sync of
  # the unchanged issue re-triggers the flow. This job closes that hole by
  # re-running the same idempotent reconciliation with backoff.
  # @spec PRIORITY-LABEL-SYNC-005
  class SyncPriorityLabelsToPullRequestJob < ApplicationJob
    include GoodJob::ActiveJobExtensions::Concurrency

    queue_as :maintenance

    # polynomially_longer across 8 attempts spans roughly 80 minutes of
    # transient GitHub unavailability. retry_on intercepts the error before
    # ApplicationJob's rescue_from hook, so notify explicitly when the
    # attempts are exhausted, then re-raise.
    retry_on GithubClient::Error, wait: :polynomially_longer, attempts: 8 do |job, error|
      Rails.logger.error(
        message: "github_sync.priority_labels_reconcile_retry_exhausted",
        issue_id: job.arguments.first,
        error_class: error.class.name,
        error: error.message
      )
      job.notify_terminal_failure(error)
      raise error
    end

    discard_on ActiveRecord::RecordNotFound

    # A repeated inline failure while a retry for the same issue is already
    # pending is discarded; the pending retry re-runs the same idempotent
    # label diff.
    good_job_control_concurrency_with(
      enqueue_limit: 1,
      key: -> { "issues_sync_priority_labels_to_pull_request_#{arguments.first}" }
    )

    def notification_project_id
      TenantContext.with_system_access { Issue.where(id: arguments.first).pick(:project_id) }
    end

    def perform(issue_id) # @spec PRIORITY-LABEL-SYNC-005
      Issues::SyncPriorityLabelsToPullRequest.call!(issue: Issue.find(issue_id))
    end

    private

    # This job receives an issue ID rather than a project or agent-run ID. Both
    # the tenant wrapper and terminal retry notification run this lookup under
    # system access through ApplicationJob.
    def tenant_account
      Issue.includes(project: :account).find_by(id: arguments.first)&.project&.account
    end
  end
end
