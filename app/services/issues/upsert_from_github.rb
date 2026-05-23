# frozen_string_literal: true

module Issues
  # Label used to surface the recommend_close recommendation on GitHub.
  # Mirrors HandleNoOutputIssueRunActivity::PAID_RECOMMEND_CLOSE_LABEL but
  # duplicated here to avoid a temporal-activity dependency on this service.
  RECOMMEND_CLOSE_LABEL = "paid-recommend-close"

  class UpsertFromGithub
    def self.call(project:, github_issue:, body: github_issue.body)
      issue = project.issues.find_or_initialize_by(github_issue_id: github_issue.id)
      was_open = issue.github_state == "open"
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
        github_updated_at: github_issue.updated_at
      )

      deliver_completion_notifications(issue, github_issue: github_issue, was_open: was_open)
      maybe_clear_recommend_close(issue, project: project, previous_labels: previous_labels, new_labels: new_labels)
      issue
    end

    def self.extract_labels(github_issue)
      Array(github_issue.labels).map { |label| label.respond_to?(:name) ? label.name : label.to_s }
    end
    private_class_method :extract_labels

    def self.pull_request_payload(github_issue)
      github_issue.respond_to?(:pull_request) ? github_issue.pull_request : nil
    end
    private_class_method :pull_request_payload

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

      label = project.label_for_stage("recommend_close") || RECOMMEND_CLOSE_LABEL
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
