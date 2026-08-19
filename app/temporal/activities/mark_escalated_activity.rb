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

      unless escalation_still_applies?(project, issue, input:)
        record_noop_decision(project, issue, reason: input[:reason], phase_before:)
        return { updated: false }
      end

      # Escalation invalidates the prior "ready" claim. Strip the label
      # before applying paid-escalated so human triage queues and any
      # "merge when green" automation never see a window where both
      # labels coexist on the same PR.
      remove_ready_label(client, project, issue)
      add_phase_label(client, project, issue.github_number, PAID_ESCALATED_LABEL)
      reason_key = resolve_escalation_reason(input)
      # The escalated phase is the whole hold — no pause flag. A system-set
      # scan exclusion would hide the PR from the scan that detects its
      # recovery. Queued runs are left alone: the hold governs what work is
      # decided next, not what is already in flight.
      # @spec PR-ESCALATION-002 @spec PR-ESCALATION-004
      issue.update!(
        pr_review_phase: "escalated",
        pr_escalation_reason: reason_key,
        labels: escalated_labels(issue)
      )
      post_escalation_comment(client, project, issue, input[:reason], reason_key:, phase_before:)
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

    def escalation_still_applies?(project, issue, input:)
      return true unless resolve_escalation_reason(input) == Issue::PR_ESCALATION_REASON_OPERATIONAL_FAILURES

      progress_state = PullRequests::ProgressState.call(project:, issue:)
      operational_failure_breaker_holds?(issue, progress_state)
    end

    def operational_failure_breaker_holds?(issue, progress_state)
      progress_state.consecutive_operational_failures >= Activities::ScanPaidPrsActivity::MAX_CONSECUTIVE_OPERATIONAL_FAILURES &&
        !progress_state.all_provider_transient_outages? &&
        escalation_confirmed?(issue)
    end

    # Re-validates the scan-confirmation gate at escalation time. The count is
    # advanced once per scan by ScanPaidPrsActivity#update_stuck_confirmation!,
    # so it reflects how many active scans confirmed the stuck state — never
    # inflated by Paid downtime.
    def escalation_confirmed?(issue)
      issue.stuck_confirmation_count.to_i >= Activities::ScanPaidPrsActivity::REQUIRED_STUCK_CONFIRMATIONS
    end

    def record_noop_decision(project, issue, reason:, phase_before:)
      logger.info(
        message: "pr_review.skip_stale_escalation",
        issue_id: issue.id,
        pr_number: issue.github_number,
        reason: reason
      )

      OrchestrationDecision.record(
        project: project,
        issue: issue,
        decision_point: "mark_escalated",
        action: "escalate",
        status: "noop",
        signals: {
          trigger: "escalate_to_owner",
          reason: reason,
          phase_before: phase_before
        },
        result: {
          updated: false,
          phase: issue.pr_review_phase
        }
      )
    end

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

    def escalated_labels(issue)
      updated_labels = issue.labels - [ MarkPrReadyActivity::PAID_READY_LABEL ]
      updated_labels << PAID_ESCALATED_LABEL unless updated_labels.include?(PAID_ESCALATED_LABEL)
      updated_labels
    end

    # Best-effort dedupe: skips posting if COMMENT_MARKER is found in the most
    # recent 100 comments. On very long-lived PRs with 100+ comments after the
    # escalation note, a retry could post a duplicate. Acceptable because
    # escalation is rare and full pagination would waste API rate limit.
    def post_escalation_comment(client, project, issue, reason, reason_key:, phase_before:)
      return if escalation_comment_exists?(client, project, issue)

      body = build_escalation_comment(reason, project, issue, reason_key:, phase_before:)
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

    def build_escalation_comment(reason, project, issue, reason_key:, phase_before:)
      reason = default_reason(project, issue, phase_before:) if reason.blank?
      owner = project.owner_reviewer_login

      lines = [ COMMENT_MARKER, "**Escalation Note**", "" ]
      lines << "This has been escalated because #{reason}."
      lines << "@#{owner} — manual review is required." if owner.present?
      lines << ""
      lines << "**How to resolve:**"
      lines << "- **Approve** this PR to allow auto-merge (if enabled)"
      lines.concat(escalation_resolution_steps(reason_key))
      lines << ""
      lines << "Auto-continue follow-ups are paused until the escalation is dismissed."
      lines.join("\n")
    end

    def escalation_resolution_steps(reason_key)
      if reason_key == Issue::PR_ESCALATION_REASON_PR_AUTO_CONTINUE_TOKEN_LIMIT
        return [
          "- **Raise `Max PR Auto-Continue Tokens`** in project settings to resume automatic follow-ups",
          "- **Remove the `paid-escalated` label** after raising the limit to let automation try again"
        ]
      end

      [
        "- **Remove the `paid-escalated` label** to dismiss escalation and let automation try again",
        "- **Convert to draft** on GitHub to restart the automated review cycle"
      ]
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

    # Resolves the durable, machine-readable escalation reason. Prefers the
    # explicit key threaded through the escalation payload by the scanner, which
    # classifies the cause from structured lifecycle signals rather than prose.
    # Falls back to inferring the key from the human-facing reason text only for
    # escalations enqueued before the key was threaded (older workflow histories
    # carry the prose but no key).
    def resolve_escalation_reason(input)
      key = input[:reason_key]
      return key if Issue::PR_ESCALATION_REASONS.include?(key)

      infer_reason_key_from_text(input[:reason])
    end

    # Legacy fallback: infer the reason key by matching the human-facing reason
    # text. Only used for in-flight escalations that predate explicit reason-key
    # threading; new escalations always carry an explicit key.
    def infer_reason_key_from_text(reason)
      if reason&.include?("consecutive provider/infrastructure failures")
        return Issue::PR_ESCALATION_REASON_OPERATIONAL_FAILURES
      end
      return Issue::PR_ESCALATION_REASON_REVIEW_GOAL_RETRY_LIMIT if reason&.start_with?("Review-goal retry budget exhausted")
      return Issue::PR_ESCALATION_REASON_PR_AUTO_CONTINUE_TOKEN_LIMIT if reason&.include?("PR auto-continue token limit")

      Issue::PR_ESCALATION_REASON_FAILURE_STREAK
    end

    def draft_originated?(issue, phase_before)
      return phase_before.in?(%w[draft restarted]) if phase_before.present?
      return issue.draft_phase? if issue.respond_to?(:draft_phase?)

      issue.pr_review_phase.in?(%w[draft restarted])
    end
  end
end
