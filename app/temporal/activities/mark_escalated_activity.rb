# frozen_string_literal: true

module Activities
  # Transitions a PR issue to the "escalated" phase. Used when the draft
  # review limit is reached and the owner needs to intervene.
  class MarkEscalatedActivity < BaseActivity
    activity_name "MarkEscalated"

    PAID_ESCALATED_LABEL = "paid-escalated"
    COMMENT_MARKER = "<!-- paid:escalation-note -->"

    def execute(input)
      issue = Issue.find_by(id: input[:issue_id])
      return { updated: false } unless issue

      project = issue.project
      client = project.client
      phase_before = issue.pr_review_phase
      issue.update!(
        pr_review_phase: "escalated",
        pr_escalation_reason: escalation_reason_key(input[:reason])
      )

      # Escalation invalidates the prior "ready" claim. Strip the label
      # before applying paid-escalated so human triage queues and any
      # "merge when green" automation never see a window where both
      # labels coexist on the same PR.
      remove_ready_label(client, project, issue)
      add_phase_label(client, project, issue.github_number, PAID_ESCALATED_LABEL)
      post_escalation_comment(client, project, issue, input[:reason], phase_before:)

      logger.info(
        message: "pr_review.marked_escalated",
        issue_id: issue.id,
        pr_number: issue.github_number
      )

      OrchestrationDecision.record(
        project: project,
        issue: issue,
        decision_point: "mark_escalated",
        action: "escalate",
        status: "applied",
        signals: {
          trigger: "escalate_to_owner",
          reason: input[:reason],
          phase_before: phase_before
        },
        result: {
          updated: true,
          phase: issue.pr_review_phase
        }
      )

      { updated: true }
    end

    private

    def remove_ready_label(client, project, issue)
      label = MarkPrReadyActivity::PAID_READY_LABEL
      return unless issue.has_label?(label)

      client.remove_label_from_issue(project.full_name, issue.github_number, label)
    rescue GithubClient::Error => e
      logger.warn(
        message: "pr_review.remove_ready_label_failed",
        issue_id: issue.id,
        pr_number: issue.github_number,
        error: e.message
      )
    end

    # Best-effort dedupe: skips posting if COMMENT_MARKER is found in the most
    # recent 100 comments. On very long-lived PRs with 100+ comments after the
    # escalation note, a retry could post a duplicate. Acceptable because
    # escalation is rare and full pagination would waste API rate limit.
    def post_escalation_comment(client, project, issue, reason, phase_before:)
      return if escalation_comment_exists?(client, project, issue)

      body = build_escalation_comment(reason, project, issue, phase_before:)
      client.add_comment(project.full_name, issue.github_number, body)
    rescue GithubClient::Error => e
      logger.warn(
        message: "pr_review.escalation_comment_failed",
        issue_id: issue.id,
        pr_number: issue.github_number,
        error: e.message
      )
    end

    # Checks the most recent 100 comments for an existing escalation note.
    # On fetch failure, returns false so we fall through to attempt posting.
    def escalation_comment_exists?(client, project, issue)
      comments = client.recent_issue_comments(project.full_name, issue.github_number)
      exists = comments.any? { |c| c.respond_to?(:body) && c.body&.include?(COMMENT_MARKER) }

      if exists
        logger.info(
          message: "pr_review.escalation_comment_exists",
          issue_id: issue.id,
          pr_number: issue.github_number
        )
      end

      exists
    rescue GithubClient::Error => e
      logger.warn(
        message: "pr_review.fetch_escalation_comments_failed",
        issue_id: issue.id,
        pr_number: issue.github_number,
        error: e.message
      )
      false
    end

    def build_escalation_comment(reason, project, issue, phase_before:)
      reason = default_reason(project, issue, phase_before:) if reason.blank?
      owner = project.owner_reviewer_login

      lines = [ COMMENT_MARKER, "**Escalation Note**", "" ]
      lines << "This has been escalated because #{reason}."
      lines << "@#{owner} — manual review is required." if owner.present?
      lines << ""
      lines << "**How to resolve:**"
      lines << "- **Approve** this PR to allow auto-merge (if enabled)"
      lines << "- **Remove the `paid-escalated` label** to dismiss escalation and let automation try again"
      lines << "- **Convert to draft** on GitHub to restart the automated review cycle"
      lines.join("\n")
    end

    def default_reason(project, issue, phase_before: nil)
      limit = if draft_originated?(issue, phase_before)
        project.max_draft_review_rounds
      else
        project.max_pr_followup_runs
      end

      "the automatic PR failure limit " \
        "(#{limit} consecutive unsuccessful runs) " \
        "has been reached without meaningful progress and the PR requires human intervention"
    end

    def escalation_reason_key(reason)
      if reason&.include?("consecutive provider/infrastructure failures")
        return Issue::PR_ESCALATION_REASON_OPERATIONAL_FAILURES
      end
      return Issue::PR_ESCALATION_REASON_REVIEW_GOAL_RETRY_LIMIT if reason&.start_with?("Review-goal retry budget exhausted")

      Issue::PR_ESCALATION_REASON_FAILURE_STREAK
    end

    def draft_originated?(issue, phase_before)
      return phase_before.in?(%w[draft restarted]) if phase_before.present?
      return issue.draft_phase? if issue.respond_to?(:draft_phase?)

      issue.pr_review_phase.in?(%w[draft restarted])
    end
  end
end
