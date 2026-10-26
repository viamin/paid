# frozen_string_literal: true

module Issues
  # Label used to surface the recommend_close recommendation on GitHub.
  # Mirrors HandleNoOutputIssueRunActivity::PAID_RECOMMEND_CLOSE_LABEL but
  # duplicated here to avoid a temporal-activity dependency on this service.
  RECOMMEND_CLOSE_LABEL = "paid-recommend-close"
  # The normal upsert API resolves a design PR itself. FetchIssuesActivity has
  # already loaded that project-scoped relation, so it passes either the record
  # or nil to avoid a second lookup for every synced pull request.
  UNRESOLVED_DESIGN_PULL_REQUEST = Object.new.freeze

  class UpsertFromGithub
    def self.call(project:, github_issue:, github_pull_request: nil, design_pull_request: UNRESOLVED_DESIGN_PULL_REQUEST, body: github_issue.body, source: Issue::GITHUB_SOURCE)
      issue = project.issues.find_or_initialize_by(github_issue_id: github_issue.id)
      was_open = issue.github_state == "open"
      was_closed = issue.persisted? && issue.github_state == "closed"
      previous_labels = Array(issue.labels)

      new_labels = extract_labels(github_issue)
      issue.update!(
        github_number: github_issue.number,
        title: github_issue.title,
        body: body,
        github_creator_login: github_issue.user&.login || "unknown",
        github_state: github_issue.state,
        labels: new_labels,
        is_pull_request: pull_request_payload(github_issue).present?,
        github_created_at: github_issue.created_at,
        github_updated_at: github_issue.updated_at,
        github_html_url: github_html_url(github_issue),
        source: source
      )

      ReconcilePullRequestSource.call(pull_request: issue) if issue.is_pull_request?
      establish_local_tdd_gate(issue, project: project)
      reconcile_design_pull_request(project, github_issue, github_pull_request, design_pull_request) if issue.is_pull_request? && github_pull_request
      enqueue_design_artifact_reconciliation(project) if issue.is_pull_request?
      enqueue_readiness_evaluation_after_bootstrap_merge(project, issue, github_pull_request)

      deliver_completion_notifications(issue, github_issue: github_issue, was_open: was_open)
      require_reopen_review(issue, was_closed: was_closed)
      maybe_unpark_recommend_close_dependents(issue, was_open: was_open)
      maybe_clear_recommend_close(issue, project: project, previous_labels: previous_labels, new_labels: new_labels)
      sync_priority_labels_to_pull_request(issue, project: project, previous_labels: previous_labels, new_labels: new_labels)
      issue
    end

    # A PR sync can fail after its producing run has durably recorded the PR
    # identity. On the later reconciliation, restore the ignored-mode gate
    # from that durable run state so a missing initial local row cannot bypass
    # human test approval.
    # @spec LABEL-CONTROL-005
    def self.establish_local_tdd_gate(issue, project:)
      return unless project.label_integration_mode == "ignored"
      return unless issue.is_pull_request? && issue.tdd_review_state.nil?
      return unless test_writing_run_for?(project, issue)

      issue.with_lock do
        issue.update!(tdd_review_state: "ready_for_review") if issue.tdd_review_state.nil?
      end
    end
    private_class_method :establish_local_tdd_gate

    def self.test_writing_run_for?(project, issue)
      project.agent_runs.where(
        goal: "create_pr",
        tdd_phase: "test_writing",
        pull_request_number: issue.github_number,
        pull_request_url: issue.github_html_url
      ).exists?
    end
    private_class_method :test_writing_run_for?

    # Issue priority labels are copied onto a pull request once, at PR
    # creation (CreatePullRequestActivity#inherited_priority_labels). This
    # keeps them in sync afterward: when a non-PR issue's priority label set
    # changes, reconcile its linked open pull request's priority labels to
    # match (#4249). Skips the lookup entirely unless the priority label set
    # actually changed, so a bulk sync does not add a per-issue query for
    # every unaffected issue.
    # @spec PRIORITY-LABEL-SYNC-001
    def self.sync_priority_labels_to_pull_request(issue, project:, previous_labels:, new_labels:)
      return if issue.is_pull_request?

      return if project.priority_labels_among(previous_labels) == project.priority_labels_among(new_labels)

      SyncPriorityLabelsToPullRequest.call(issue: issue, project: project)
    end
    private_class_method :sync_priority_labels_to_pull_request

    def self.reconcile_design_pull_request(project, github_issue, github_pull_request, design_pull_request)
      return unless design_pull_request

      arguments = {
        project: project,
        github_issue: github_issue,
        github_pull_request: github_pull_request
      }
      arguments[:design_pull_request] = design_pull_request unless design_pull_request.equal?(UNRESOLVED_DESIGN_PULL_REQUEST)
      FeatureIntents::ReconcileDesignPullRequest.call(**arguments)
    end
    private_class_method :reconcile_design_pull_request

    def self.enqueue_design_artifact_reconciliation(project)
      # A merged RDR PR changes the default-branch documents even before it is
      # attached to a FeatureIntent, so every PR sync refreshes repository RDR
      # discovery and tracked design PRs.
      FeatureIntents::ReconcileDesignArtifactsJob.enqueue_for(project.id)
    end
    private_class_method :enqueue_design_artifact_reconciliation

    # The readiness snapshot is repository evidence, not a durable latch.
    # Refresh only after GitHub confirms the bootstrap PR merged, so the
    # evaluator checks the target branch rather than the agent's branch.
    # @spec PROJECT-READINESS-007
    def self.enqueue_readiness_evaluation_after_bootstrap_merge(project, issue, github_pull_request)
      return unless github_pull_request&.merged_at.present?
      return unless issue.saved_change_to_github_state?
      return unless project.agent_runs.where(goal: "bootstrap_readiness", pull_request_number: issue.github_number).exists?

      EvaluateProjectReadinessJob.perform_later(project.id)
    end
    private_class_method :enqueue_readiness_evaluation_after_bootstrap_merge

    # @spec ISSUE-REOPEN-REVIEW-001
    def self.require_reopen_review(issue, was_closed:)
      return unless was_closed
      return unless issue.github_state == "open"
      return if issue.is_pull_request?

      issue.require_reopen_review!
    end
    private_class_method :require_reopen_review

    def self.extract_labels(github_issue)
      Array(github_issue.labels).map { |label| label.respond_to?(:name) ? label.name : label.to_s }
    end
    private_class_method :extract_labels

    def self.pull_request_payload(github_issue)
      github_issue.respond_to?(:pull_request) ? github_issue.pull_request : nil
    end
    private_class_method :pull_request_payload

    def self.github_html_url(github_issue)
      github_issue.html_url if github_issue.respond_to?(:html_url)
    end
    private_class_method :github_html_url

    def self.deliver_completion_notifications(issue, github_issue:, was_open:)
      return unless was_open
      return unless issue.github_state == "closed"
      return unless closed_as_completed?(github_issue)

      event = issue.is_pull_request? ? :merged : :completed
      IssueMergeSubscriptions::Deliver.call(issue: issue, event: event)
    end
    private_class_method :deliver_completion_notifications

    def self.closed_as_completed?(github_issue)
      github_issue.respond_to?(:state_reason) && github_issue.state_reason == "completed"
    end
    private_class_method :closed_as_completed?

    def self.maybe_unpark_recommend_close_dependents(issue, was_open:) # @spec AUTO-PICK-QUEUE-003
      return unless was_open
      return unless issue.github_state == "closed"

      issue.dependents.includes(:project).where(github_state: "open", paid_state: "recommend_close").find_each do |dependent|
        next unless dependent.ready_to_work?
        next unless remove_recommend_close_label(dependent)

        label = recommend_close_label(dependent.project)
        dependent.update!(paid_state: "new", labels: dependent.labels - [ label ])
        Rails.logger.info(
          message: "recommend_close.dependency_closed_reset",
          blocker_issue_id: issue.id,
          blocker_github_number: issue.github_number,
          dependent_issue_id: dependent.id,
          dependent_github_number: dependent.github_number,
          project_id: dependent.project_id,
          removed_label: label
        )
      end
    end
    private_class_method :maybe_unpark_recommend_close_dependents

    def self.remove_recommend_close_label(issue)
      label = recommend_close_label(issue.project)
      return true unless issue.labels.include?(label)

      if issue.project.upstream_pr_target?
        Rails.logger.info(
          message: "github_sync.upstream_issue_write_skipped",
          project_id: issue.project_id,
          issue_id: issue.id,
          github_number: issue.github_number,
          operation: "remove_recommend_close_label"
        )
        return true
      end

      client = issue.project.client
      if client.nil?
        Rails.logger.warn(
          message: "recommend_close.dependency_closed_reset_label_remove_skipped",
          issue_id: issue.id,
          project_id: issue.project_id,
          github_number: issue.github_number,
          label: label
        )
        return false
      end

      client.remove_label_from_issue(issue.project.full_name, issue.github_number, label)
      true
    rescue GithubClient::Error => e
      Rails.logger.warn(
        message: "recommend_close.dependency_closed_reset_label_remove_failed",
        issue_id: issue.id,
        project_id: issue.project_id,
        github_number: issue.github_number,
        label: label,
        error: e.message
      )
      false
    end
    private_class_method :remove_recommend_close_label

    def self.recommend_close_label(project)
      project.label_for_stage("recommend_close") || RECOMMEND_CLOSE_LABEL
    end
    private_class_method :recommend_close_label

    # When a user removes the recommend-close label from an issue that Paid
    # had parked in paid_state=recommend_close, treat that as an explicit
    # "I disagree, work on this again" signal. Reset paid_state to new — the
    # Issue model's auto_pick_recheck_needed? callback handles re-enqueueing
    # when paid_state transitions to an eligible value. We do not act on
    # label *additions* — only Paid itself should add the recommend-close
    # label as part of its classification.
    def self.maybe_clear_recommend_close(issue, project:, previous_labels:, new_labels:)
      return if issue.is_pull_request?
      return unless issue.paid_state == "recommend_close"

      label = recommend_close_label(project)
      return unless previous_labels.include?(label)
      return if new_labels.include?(label)

      issue.update!(paid_state: "new")
      Rails.logger.info(
        message: "recommend_close.label_removed_reset",
        issue_id: issue.id,
        project_id: project.id,
        github_number: issue.github_number
      )
    end
    private_class_method :maybe_clear_recommend_close
  end
end
