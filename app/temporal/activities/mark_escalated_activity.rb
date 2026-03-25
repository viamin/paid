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
      client = project.github_token.client
      issue.update!(pr_review_phase: "escalated")

      add_phase_label(client, project, issue.github_number, PAID_ESCALATED_LABEL)
      post_escalation_comment(client, project, issue, input[:reason])

      logger.info(
        message: "pr_review.marked_escalated",
        issue_id: issue.id,
        pr_number: issue.github_number
      )

      { updated: true }
    end

    private

    # Idempotent: skips posting if a comment with COMMENT_MARKER already exists.
    # This guards against duplicates when Temporal retries the activity.
    def post_escalation_comment(client, project, issue, reason)
      return if escalation_comment_exists?(client, project, issue)

      body = build_escalation_comment(reason, project, issue)
      client.add_comment(project.full_name, issue.github_number, body)
    rescue GithubClient::Error => e
      logger.warn(
        message: "pr_review.escalation_comment_failed",
        issue_id: issue.id,
        pr_number: issue.github_number,
        error: e.message
      )
    end

    # Returns true when a prior escalation comment is found. On fetch failure,
    # returns false so we fall through to attempt posting.
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

    def build_escalation_comment(reason, project, issue)
      reason = default_reason(project, issue) if reason.blank?

      lines = [ COMMENT_MARKER, "**Escalation Note**", "" ]
      lines << "This has been escalated because #{reason}."
      lines << ""
      lines << "**Questions:**"
      lines << "- Are there specific changes you'd like to see in the pull request?"
      lines << "- Should the automated review cycle be restarted with different guidance?"
      lines.join("\n")
    end

    def default_reason(project, issue)
      "the automated draft review limit " \
        "(#{project.max_draft_review_rounds} rounds) " \
        "has been reached after #{issue.draft_review_count} review cycles " \
        "and the PR requires human intervention"
    end
  end
end
