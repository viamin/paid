# frozen_string_literal: true

module Issues
  # Reconciles a pull request's priority labels to match its linked issue's
  # whenever the issue's priority label set changes after PR creation
  # (#4249). CreatePullRequestActivity#inherited_priority_labels only copies
  # priority labels once, at PR creation; this keeps them in sync for the
  # life of the PR by adding newly-set priority labels and removing ones the
  # issue no longer carries. Only labels in project.priority_label_names are
  # ever touched — human-added non-priority labels are untouched.
  # @spec PRIORITY-LABEL-SYNC-001 PRIORITY-LABEL-SYNC-002 PRIORITY-LABEL-SYNC-003 PRIORITY-LABEL-SYNC-004 PRIORITY-LABEL-SYNC-005
  class SyncPriorityLabelsToPullRequest
    # Inline entry point (Issues::UpsertFromGithub sync path): a transient
    # GithubClient::Error is logged (PRIORITY-LABEL-SYNC-004) and retried
    # asynchronously (PRIORITY-LABEL-SYNC-005) rather than raised — the
    # issue's new labels are already persisted at this point, so a later
    # sync of the unchanged issue will not re-trigger the reconciliation.
    def self.call(issue:, project:)
      reconcile(issue: issue, project: project)
    rescue GithubClient::Error
      SyncPriorityLabelsToPullRequestJob.perform_later(issue.id)
    end

    # Raised-error entry point for the retry job: same reconciliation, but a
    # GithubClient::Error propagates so the job's retry_on policy drives
    # bounded backoff instead of enqueueing another job here.
    # @spec PRIORITY-LABEL-SYNC-005
    def self.call!(issue:)
      reconcile(issue: issue, project: issue.project)
    end

    def self.reconcile(issue:, project:)
      return unless project.inherit_priority_labels?

      pull_request = issue.associated_paid_pull_request
      return unless pull_request

      to_add, to_remove = label_diff(project, issue, pull_request)
      return if to_add.empty? && to_remove.empty?

      reconcile_labels(project, pull_request, to_add: to_add, to_remove: to_remove)
    end
    private_class_method :reconcile

    def self.label_diff(project, issue, pull_request)
      desired = project.priority_labels_among(issue.labels)
      current = project.priority_labels_among(pull_request.labels)
      [ desired - current, current - desired ]
    end
    private_class_method :label_diff

    def self.reconcile_labels(project, pull_request, to_add:, to_remove:)
      client = project.client
      return unless client

      removed = apply_label_changes(client, project, pull_request, to_add: to_add, to_remove: to_remove)
      persist_local_labels(pull_request, to_add: to_add, removed: removed)
      log_reconciled(project, pull_request, added: to_add, removed: removed)
    rescue GithubClient::Error => e
      log_reconcile_failed(project, pull_request, e)
      raise
    end
    private_class_method :reconcile_labels

    def self.apply_label_changes(client, project, pull_request, to_add:, to_remove:)
      client.add_labels_to_issue(project.full_name, pull_request.github_number, to_add) if to_add.any?
      return [] if to_remove.empty?

      client.remove_labels_from_issue(project.full_name, pull_request.github_number, to_remove)[:removed]
    end
    private_class_method :apply_label_changes

    def self.persist_local_labels(pull_request, to_add:, removed:)
      pull_request.with_lock do
        pull_request.update!(labels: ((pull_request.labels - removed) + to_add).uniq)
      end
    end
    private_class_method :persist_local_labels

    def self.log_reconciled(project, pull_request, added:, removed:)
      Rails.logger.info(
        message: "github_sync.priority_labels_reconciled",
        project_id: project.id,
        pull_request_id: pull_request.id,
        github_number: pull_request.github_number,
        added: added,
        removed: removed
      )
    end
    private_class_method :log_reconciled

    def self.log_reconcile_failed(project, pull_request, error)
      Rails.logger.warn(
        message: "github_sync.priority_labels_reconcile_failed",
        project_id: project.id,
        pull_request_id: pull_request.id,
        github_number: pull_request.github_number,
        error: error.message
      )
    end
    private_class_method :log_reconcile_failed
  end
end
