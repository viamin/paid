# frozen_string_literal: true

module Activities
  # Records that a PR follow-up was triggered by incrementing the
  # pr_followup_count and removing actionable labels. Called by the
  # polling workflow after queueing a create_pr follow-up run.
  #
  # Idempotent: uses the expected_followup_count parameter to prevent
  # double-counting on Temporal retries. The increment only applies
  # when the current count matches the expected value.
  #
  # Phantom-increment guard: only records when an unfinished run exists
  # for the issue. Without this, a skipped QueueAgentRunActivity (e.g.,
  # untrusted issue, duplicate) still increments the counter — inflating
  # it while zero runs execute and defeating the followup-limit escalation
  # breaker (which counts consecutive unsuccessful AgentRun records, not
  # counter increments).
  class RecordPrFollowupActivity < BaseActivity
    activity_name "RecordPrFollowup"

    def execute(input)
      project = Project.find_by(id: input[:project_id])
      return { recorded: false } unless project

      issue = project.issues.find_by(id: input[:issue_id])
      return { recorded: false } unless issue

      has_active_run = project.agent_runs
        .where(
          issue_id: issue.id,
          goal: "create_pr",
          source_pull_request_number: issue.github_number,
          status: AgentRun::UNFINISHED_STATUSES
        )
        .exists?

      unless has_active_run
        logger.info(
          message: "pr_scanner.followup_skipped_no_active_run",
          project_id: project.id,
          issue_id: issue.id,
          pr_number: issue.github_number
        )
        return { recorded: false, skipped: true, reason: "no_active_run" }
      end

      expected_count = input[:expected_followup_count]
      if expected_count
        # Use a row lock and instance-level increment so callbacks/timestamps fire.
        issue.with_lock do
          issue.reload
          issue.increment!(:pr_followup_count) if issue.pr_followup_count == expected_count
        end
      else
        # Legacy callers without expected_count fall back to unconditional increment.
        issue.increment!(:pr_followup_count)
      end

      remove_labels(project, issue, input[:labels_to_remove] || [])

      { recorded: true }
    end

    private

    def remove_labels(project, issue, labels)
      return if labels.empty?

      client = project.client
      labels.each do |label|
        client.remove_label_from_issue(project.full_name, issue.github_number, label)
      rescue GithubClient::Error => e
        logger.warn(
          message: "pr_scanner.remove_label_failed",
          project_id: project.id,
          pr_number: issue.github_number,
          label: label,
          error: e.message
        )
      end
    end
  end
end
