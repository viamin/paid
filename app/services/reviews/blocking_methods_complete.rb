# frozen_string_literal: true

module Reviews
  # Decides whether every enabled blocking review method has a completion
  # signal for a pull request. Shared by the PR scan
  # (Activities::ScanPaidPrsActivity) and the awaiting_approval escalation
  # re-validation (PullRequests::BlockedOnlyOnApproval) so both sides apply
  # the same gates — the re-validation must neither hold a PR the scan
  # would pass nor release one the scan holds.
  #
  # Review methods and their completion criteria:
  #
  #   paid_agent (sole bot method, non-escalated PRs only) — the most
  #     recent finished review-goal run must not be a failure that posted
  #     no review. A failed, unposted run means the required review never
  #     landed, so the gate holds until a run succeeds (or the retry-limit
  #     escalation path releases it by escalating). Outstanding feedback
  #     from a review that *was* posted is still checked by the caller's
  #     review-feedback gate.
  #   copilot / codex — checked by the caller's review-feedback gates
  #     (review bot status + thread resolution). Not re-checked here.
  #   ci_action — the check run named by action_name must be present
  #     and have a successful conclusion.
  #   manual — at least one trusted non-bot user must have submitted
  #     an APPROVED review (distinct from owner approval, which gates
  #     the merge trigger itself).
  class BlockingMethodsComplete
    def self.call(project:, issue:, reviews:, checks:, pr_data:, progress_state: nil)
      return true unless project.review_enabled? && project.wait_for_reviews?

      if paid_agent_review_unposted_failure?(project:, issue:, reviews:, progress_state:)
        return false
      end

      if project.review_method_enabled?("ci_action")
        return false unless ci_action_review_complete?(project:, checks:, pr_data:)
      end

      if project.review_method_enabled?("manual")
        return false unless manual_review_complete?(project:, reviews:)
      end

      true
    end

    # Returns true when paid_agent is the only enabled bot review method,
    # meaning no other bot can keep gating the PR on its behalf.
    def self.paid_agent_sole_review_method?(project)
      return false unless project&.review_enabled?
      return false unless project.review_method_enabled?("paid_agent")

      bot_methods = project.enabled_review_methods & %w[copilot codex paid_agent]
      bot_methods == %w[paid_agent]
    end

    # ci_action is complete when the configured action_name appears in the
    # check-run list with a "success" conclusion. Also exposed for the
    # scan's ci_action_pending trigger, which reports the same predicate.
    def self.ci_action_review_complete?(project:, checks:, pr_data:)
      action_name = project.review_method(:ci_action).action_name
      if action_name.blank?
        Rails.logger.warn(message: "reviews.ci_action_missing_action_name", project_id: project.id)
        return false
      end

      return true if ci_action_check_skipped_for_fork?(action_name, pr_data)

      Array(checks).any? { |c| c[:name] == action_name.strip && c[:conclusion] == "success" }
    end

    # Returns true when paid_agent is enabled as the SOLE bot review method,
    # the PR is still in a review-gated phase (not escalated), no paid_agent
    # review has been posted, and the most recent finished review-goal run in
    # the current cycle ended in a retryable failure status without posting a
    # review. The PR then never received the required review, so the
    # completion gate must hold until a run succeeds, or until exhausting
    # retries drives the escalation path (which moves the PR to the
    # escalated phase, exempt below). A posted review — clean or not — is
    # left to the caller's review-feedback gate, so this only closes the
    # "review never landed" hole (#3086).
    #
    # Scope is deliberately narrow:
    # - Sole-method only: mixed-bot projects (e.g. copilot + paid_agent) do
    #   NOT escalate on paid_agent exhaustion — the other bot is meant to keep
    #   gating. Blocking here for a mixed project would deadlock with no
    #   recovery.
    # - Escalated PRs are exempt: owner approval intentionally unblocks
    #   auto-merge for an escalated PR, and the race this guard prevents
    #   (merge firing before escalation confirms) is already resolved once
    #   the PR has escalated.
    def self.paid_agent_review_unposted_failure?(project:, issue:, reviews:, progress_state: nil)
      return false if issue.escalated_phase?
      return false unless paid_agent_sole_review_method?(project)
      return false if paid_agent_review_present?(reviews)

      state = progress_state || PullRequests::ProgressState.call(project:, issue:)
      latest_run = Reviews::AutomaticRunHistory.latest_finished(project:, issue:, progress_state: state)
      return false unless latest_run&.status&.in?(Reviews::AutomaticRunHistory::RETRYABLE_FAILURE_STATUSES)
      return false if latest_run.review_posted_at.present?

      true
    end

    # Returns true when any posted review came from the paid_agent review bot.
    def self.paid_agent_review_present?(reviews)
      return false if reviews.blank?

      reviews.any? { |review| RunnerSupport.runner_bot_username_for?("paid_agent", review[:user_login]) }
    end
    private_class_method :paid_agent_review_present?

    # Claude-review CI actions do not run on fork PRs, so the missing check
    # must not hold completion.
    def self.ci_action_check_skipped_for_fork?(action_name, pr_data)
      claude_review_action?(action_name) && pr_data&.head&.repo&.fork == true
    end
    private_class_method :ci_action_check_skipped_for_fork?

    def self.claude_review_action?(action_name)
      action_name.strip == Activities::DispatchClaudeReviewActivity::ACTION_NAME
    end
    private_class_method :claude_review_action?

    # Manual review is complete when the configured reviewer_login's latest
    # trusted non-bot review is APPROVED. This matches GitHub's
    # latest-review-wins semantics, so a later COMMENTED or
    # CHANGES_REQUESTED review re-opens the gate instead of leaving a stale
    # earlier approval in force.
    def self.manual_review_complete?(project:, reviews:)
      return false if reviews.nil?

      reviewer = project.review_method(:manual).reviewer_login
      return false if reviewer.blank?

      latest_review = latest_trusted_non_bot_review_for(project:, reviews:, reviewer_login: reviewer)
      latest_review&.dig(:state) == "APPROVED"
    end

    def self.latest_trusted_non_bot_review_for(project:, reviews:, reviewer_login:)
      normalized_login = reviewer_login.strip.downcase

      reviewer_reviews = reviews.select do |review|
        review[:user_login]&.downcase == normalized_login &&
          project.trusted_github_user?(review[:user_login]) &&
          !bot_user?(review[:user_login])
      end
      return nil if reviewer_reviews.empty?

      reviewer_reviews.max_by { |review| review[:submitted_at] || Time.at(0) }
    end
    private_class_method :latest_trusted_non_bot_review_for

    def self.bot_user?(login)
      Reviews::BotDetection.bot_user?(login)
    end
    private_class_method :bot_user?
  end
end
