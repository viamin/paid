# frozen_string_literal: true

module PullRequests
  # Re-validates that a ready-phase pull request is currently blocked only on
  # owner approval. Mirrors the scan's
  # {Activities::ScanPaidPrsActivity#blocked_only_on_approval?} gate against
  # fresh GitHub data, so the awaiting_approval escalation cannot be applied
  # to a PR whose state changed between the scan's observation and the
  # activity. Cheap DB-only checks (open, ready_phase?, label) miss the
  # non-approval blockers that can appear in the race window: CI can start
  # failing, a dependency can become unresolved, or new review feedback can
  # land between the scan and the escalation activity.
  #
  # Returns false on any transient API failure that prevents verification —
  # we err on the side of skipping the escalation rather than escalating a PR
  # whose state we cannot confirm, because escalating a PR that is actually
  # blocked for a non-approval reason misleads the owner into thinking
  # approval alone will clear it.
  #
  # @spec PR-ESCALATION-025
  class BlockedOnlyOnApproval
    SKIP_AUTO_MERGE_LABEL = Automation::Strategies::AutoMerge::SKIP_AUTO_MERGE_LABEL

    def self.call(project:, client:, issue:, logger: Rails.logger)
      new(project:, client:, issue:, logger:).call
    end

    def initialize(project:, client:, issue:, logger:)
      @project = project
      @client = client
      @issue = issue
      @logger = logger
    end

    def call
      return false unless quick_preconditions_hold?

      pr_data = fetch_pull_request
      return false if pr_data.nil?
      return false if draft?(pr_data) || closed?(pr_data)
      return false if skip_auto_merge_label?(pr_data)
      return false unless mergeable?(pr_data)

      checks = fetch_check_runs(pr_data)
      return false if checks.nil?
      return false unless all_checks_green?(checks)

      reviews = fetch_reviews
      return false if reviews.nil?
      return false if owner_approved_or_self_authored?(reviews, pr_data)

      unresolved_threads = fetch_unresolved_threads
      return false if unresolved_threads.nil?

      signals = build_signals(pr_data:, checks:, reviews:, unresolved_threads:)
      return false if signals.nil?

      blocked_only_on_approval?(signals)
    rescue GithubClient::Error, Automation::Providers::RepositoryProvider::ProviderError,
           Automation::Providers::ReviewProvider::ProviderError => e
      @logger.warn(
        message: "pr_review.blocked_only_on_approval_check_failed",
        project_id: @project.id,
        pr_number: @issue.github_number,
        error_class: e.class.name,
        error: e.message
      )
      false
    end

    private

    def quick_preconditions_hold?
      @project.auto_merge_enabled? &&
        @project.owner_reviewer_login.present? &&
        @issue.github_state == "open" &&
        @issue.ready_phase? &&
        !@issue.has_label?(SKIP_AUTO_MERGE_LABEL)
    end

    def collector
      @collector ||= Automation::Signals::PullRequestCollector.new(
        providers: Automation::Signals::ProviderContext.for(@project, client: @client),
        client: @client,
        logger: @logger
      )
    end

    def fetch_pull_request
      collector.fetch_pull_request(issue: @issue)
    end

    def fetch_check_runs(pr_data)
      collector.fetch_check_runs(pr_data: pr_data)
    end

    def fetch_reviews
      collector.fetch_reviews(issue: @issue)
    end

    def fetch_unresolved_threads
      collector.fetch_unresolved_threads(issue: @issue)
    end

    def mergeable?(pr_data)
      pr_data.respond_to?(:mergeable) ? pr_data.mergeable == true : pr_data[:mergeable] == true
    end

    def draft?(pr_data)
      pr_data.respond_to?(:draft) ? pr_data.draft == true : pr_data[:draft] == true
    end

    def closed?(pr_data)
      state = pr_data.respond_to?(:state) ? pr_data.state : pr_data[:state]
      state.to_s.casecmp?("closed")
    end

    def all_checks_green?(checks)
      Reviews::ChecksStatus.all_green?(checks)
    end

    def owner_approved_or_self_authored?(reviews, pr_data)
      Reviews::OwnerApproval.approved_or_self_authored?(project: @project, reviews:, pr_data:)
    end

    def build_signals(pr_data:, checks:, reviews:, unresolved_threads:)
      reviews_fresh = fresh_reviews?(pr_data, reviews)
      review_feedback_clear = no_outstanding_review_feedback?(pr_data, reviews, unresolved_threads)
      blocking_reviews_complete = blocking_reviews_complete?(reviews, checks, pr_data)
      dependencies_resolved = dependencies_resolved?

      Automation::Strategies::AutoMerge::Signals.build(
        issue_id: @issue.id,
        pr_number: @issue.github_number,
        owner_approved: owner_approved_or_self_authored?(reviews, pr_data),
        checks_green: all_checks_green?(checks),
        mergeable: mergeable?(pr_data),
        review_feedback_clear: review_feedback_clear,
        blocking_reviews_complete: blocking_reviews_complete,
        reviews_fresh: reviews_fresh,
        dependencies_resolved: dependencies_resolved,
        skip_auto_merge: skip_auto_merge_label?(pr_data)
      )
    end

    # Reads the skip-auto-merge label from the freshly fetched PR data
    # (PullRequestSnapshot#labels, already normalized to plain strings by
    # the provider layer) rather than the persisted Issue#labels copy, so a
    # label added on GitHub after the scan (but before the local sync
    # catches up) still blocks this escalation.
    def skip_auto_merge_label?(pr_data)
      Array(pr_data.labels).include?(SKIP_AUTO_MERGE_LABEL)
    end

    # Mirrors the scan's blocked_only_on_approval? gate signal-for-signal:
    # the PR must still be green, mergeable, free of outstanding review
    # feedback and unresolved dependencies, past every blocking review
    # method, and held only by the approval gate.
    def blocked_only_on_approval?(signals)
      !signals.owner_approved? &&
        signals.checks_green? &&
        signals.mergeable? &&
        signals.review_feedback_clear? &&
        signals.blocking_reviews_complete? &&
        signals.reviews_fresh? &&
        signals.dependencies_resolved? &&
        !signals.skip_auto_merge?
    end

    # Mirrors the scan's review_stale_for_head?: the head commit must not
    # postdate the latest approval from any enabled blocking reviewer,
    # unless every commit since that approval is a clean merge of the base
    # branch (see AUTO-MERGE-006). The owner's approval is always checked;
    # the manual reviewer's is checked separately when the manual method is
    # enabled, so a fresh owner re-approval cannot mask a stale manual
    # review. Skipped (returns true) when the head commit timestamp can't
    # be resolved — matches the scan's behavior of returning false only on
    # a confirmed staleness.
    def fresh_reviews?(pr_data, reviews)
      return true if reviews.nil?

      head_committed_at = fetch_head_commit_date(pr_data)
      return true if head_committed_at.nil?

      !stale_approval?(head_committed_at, reviews, pr_data)
    end

    def fetch_head_commit_date(pr_data)
      collector.fetch_head_commit_date(issue: @issue, pr_data: pr_data)
    end

    # Mirrors the scan's review_stale_for_head? commit-graph replay: a
    # timestamp-stale approval is only treated as blocking when the range
    # between the approved commit and HEAD carries author-side content.
    # An approval with no recorded commit_id, or a range that can't be
    # resolved (missing head/base data), fails closed to stale.
    def stale_approval?(head_committed_at, reviews, pr_data)
      approvals = blocking_approvals_for(reviews)
      return false if approvals.empty?

      head_sha = pr_data.head_sha
      base_branch = pr_data.base_ref
      return true if head_sha.blank? || base_branch.blank?

      approvals.any? do |approval|
        next false unless head_committed_at > approval[:submitted_at]

        commit_id = approval[:commit_id]
        next true if commit_id.blank?

        !collector.only_base_merge_commits_since?(
          approval_sha: commit_id,
          head_sha: head_sha,
          base_branch: base_branch,
          issue: @issue
        )
      end
    end

    # Latest {submitted_at:, commit_id:} pair for each enabled blocking
    # reviewer: the owner (always) and the configured manual reviewer
    # (when the manual method is enabled). Mirrors the scan's
    # blocking_approvals_for so both sides hold the same approvals to the
    # same freshness rule, including the commit_id needed to replay the
    # clean-base-merge check.
    def blocking_approvals_for(reviews)
      approvals = []

      owner_approval = latest_approval_for(reviews, @project.owner_reviewer_login)
      approvals << owner_approval if owner_approval

      if @project.review_method_enabled?("manual")
        reviewer = @project.review_method(:manual).reviewer_login
        manual_approval = latest_approval_for(reviews, reviewer, trust_required: false)
        approvals << manual_approval if manual_approval
      end

      approvals
    end

    # Most recent {submitted_at:, commit_id:} among the reviewer's
    # APPROVED reviews from trusted non-bot users; nil when the reviewer
    # is unconfigured or has not approved.
    def latest_approval_for(reviews, reviewer_login, trust_required: true)
      return nil if reviewer_login.blank?

      approvals = reviews.select do |r|
        r[:state].to_s.upcase == "APPROVED" &&
          r[:user_login]&.casecmp?(reviewer_login.strip) &&
          approval_login_allowed?(r[:user_login], trust_required:) &&
          !bot_user?(r[:user_login])
      end

      latest = approvals.filter_map { |r| r[:submitted_at] }.max
      return nil if latest.nil?

      { submitted_at: latest, commit_id: approvals.find { |r| r[:submitted_at] == latest }&.dig(:commit_id) }
    end

    def approval_login_allowed?(login, trust_required:)
      !trust_required || @project.trusted_github_user?(login)
    end

    # Cheap stand-in for the scan's full no_outstanding_review_feedback? gate.
    # We re-fetch from GitHub on every escalation, so the live data is the
    # authoritative signal — no risk of a stale local copy. Each signal
    # below corresponds to one of the blockers the scan watches:
    #
    # * unresolved review threads with a trusted-human or enabled-bot comment
    # * a CHANGES_REQUESTED review from a trusted non-bot user, not yet
    #   addressed by a later completed run
    # * a fresh trusted-human conversation comment that still needs follow-up
    # * a non-clean review or unresolved thread from a bot the project has
    #   not enabled, when address_all_bot_reviews? is on
    # * the paid-skip-auto-merge label on the PR (handled in quick_preconditions)
    def no_outstanding_review_feedback?(pr_data, reviews, unresolved_threads)
      return false if recent_trusted_conversation_comments?
      return false if outstanding_review_threads?(unresolved_threads)
      return false if changes_requested?(reviews)
      return false unless review_bot_status_clear?(reviews)
      return false unless non_enabled_bot_reviews_clear?(reviews, unresolved_threads)

      true
    end

    def recent_trusted_conversation_comments?
      cutoff = last_completed_run&.completed_at
      comments = collector.fetch_recent_issue_comments(issue: @issue, cutoff:)
      return true if comments.nil?

      comments.any? do |comment|
        login = comment.user&.login
        next false if bot_user?(login)
        next false unless @project.trusted_github_user?(login)
        next false if cutoff && comment.created_at && comment.created_at <= cutoff
        next false if system_generated_comment?(comment.body)
        next false if comment.body.to_s.strip.length < Activities::ScanPaidPrsActivity::MIN_COMMENT_LENGTH

        true
      end
    end

    # Mirrors the scan's latest_allowed_bot_review + REVIEW_BOT_CLEAN_PATTERN:
    # a body-only bot review (Copilot, Codex, paid_agent) posts its findings
    # as a review body with no threads, so outstanding_review_threads? alone
    # cannot see it. Without this, a re-requested bot review that lands
    # comments in the scan-to-activity window would pass this re-validation
    # even though owner_approval_clears_merge? still blocks on it.
    def review_bot_status_clear?(reviews)
      allowed_bot_logins = allowed_review_bot_logins
      return true if allowed_bot_logins.nil?

      latest = latest_allowed_bot_review(reviews, allowed_bot_logins)
      return true if latest.nil?

      paid_agent_clean_review?(latest) ||
        Activities::ScanPaidPrsActivity::REVIEW_BOT_CLEAN_PATTERN.match?(latest[:body])
    end

    def latest_allowed_bot_review(reviews, allowed_bot_logins)
      bot_reviews = reviews.select do |r|
        RunnerSupport.runner_bot_username?(r[:user_login]) &&
          allowed_bot_logins.include?(r[:user_login]&.downcase)
      end
      bot_reviews.max_by { |r| r[:submitted_at] || Time.at(0) }
    end

    def paid_agent_clean_review?(review)
      return false unless RunnerSupport.runner_bot_username_for?("paid_agent", review[:user_login])

      review[:body]&.include?(Activities::ScanPaidPrsActivity::PAID_REVIEW_CLEAN_MARKER) || false
    end

    # Cheap mirror of the scan's check_non_enabled_bot_reviews: when the
    # project has address_all_bot_reviews? on, a review or unresolved
    # thread from a bot outside the enabled set also blocks, not just
    # bots the project explicitly configured. Simplified relative to the
    # scan's version — it does not replay the body-only-bot "needs
    # followup"/diff-touches-reviewed-files nuance, so it treats any
    # non-clean review from a non-enabled bot as blocking. That is
    # conservative in the same direction as the rest of this class: it
    # can hold a PR the scan would release, never the reverse.
    def non_enabled_bot_reviews_clear?(reviews, unresolved_threads)
      return true unless @project.address_all_bot_reviews?

      non_enabled_logins = RunnerSupport.all_bot_usernames - @project.enabled_review_bot_logins
      return true if non_enabled_logins.empty?

      return false if unresolved_threads.any? do |thread|
        thread[:comments].any? { |c| non_enabled_logins.include?(c[:author]&.downcase) }
      end

      Array(reviews)
        .select { |r| non_enabled_logins.include?(r[:user_login]&.downcase) }
        .all? { |r| paid_agent_clean_review?(r) || Activities::ScanPaidPrsActivity::REVIEW_BOT_CLEAN_PATTERN.match?(r[:body]) }
    end

    # Mirrors the scan's human_review_thread_triggers + review_bot_thread_triggers:
    # only a thread with a comment from a trusted non-bot user, or from a
    # review bot in the project's enabled set, counts as outstanding
    # feedback. A thread left by an untrusted drive-by commenter, or by a
    # bot the project has not enabled, does not block the scan and must not
    # veto this re-validation either.
    def outstanding_review_threads?(unresolved_threads)
      allowed_bot_logins = allowed_review_bot_logins

      unresolved_threads.any? do |thread|
        thread[:comments].any? do |comment|
          trusted_human_comment?(comment[:author]) || enabled_bot_comment?(comment[:author], allowed_bot_logins)
        end
      end
    end

    def trusted_human_comment?(author)
      @project.trusted_github_user?(author) && !bot_user?(author)
    end

    def enabled_bot_comment?(author, allowed_bot_logins)
      return false unless RunnerSupport.runner_bot_username?(author)
      return true if allowed_bot_logins.nil?

      allowed_bot_logins.include?(author&.downcase)
    end

    # nil means "no filtering" (review disabled); an empty Set means
    # "review enabled but no bots configured" — mirrors the scan's
    # allowed_review_bot_logins so both sides treat an unconfigured bot
    # method the same way.
    def allowed_review_bot_logins
      return nil unless @project.review_enabled?

      @project.enabled_review_bot_logins.presence || Set.new
    end

    # Latest-wins per trusted reviewer, and suppressed when the review
    # predates the last completed run in this PR's history — mirrors the
    # scan's changes_requested_from_reviews so feedback a follow-up run
    # already addressed does not veto the escalation forever.
    def changes_requested?(reviews)
      cutoff = last_completed_run&.completed_at

      latest_by_trusted_user(reviews).any? do |review|
        review[:state].to_s.upcase == "CHANGES_REQUESTED" &&
          (cutoff.nil? || review[:submitted_at].nil? || review[:submitted_at] > cutoff)
      end
    end

    def latest_by_trusted_user(reviews)
      reviews
        .select { |r| @project.trusted_github_user?(r[:user_login]) && !bot_user?(r[:user_login]) }
        .group_by { |r| r[:user_login]&.downcase }
        .transform_values { |user_reviews| user_reviews.max_by { |r| r[:submitted_at] || Time.at(0) } }
        .values
    end

    def last_completed_run
      AgentRun.pr_history_scope(project: @project, issue: @issue, pr_number: @issue.github_number)
        .completed
        .order(completed_at: :desc)
        .first
    end

    def bot_user?(login)
      Reviews::BotDetection.bot_user?(login)
    end

    def system_generated_comment?(body)
      Activities::CompleteExistingPrRunActivity.agent_update_comment?(body)
    end

    # Same gate the scan applies: every enabled blocking review method
    # (paid_agent, ci_action, manual) must still show a completion signal
    # against the freshly fetched reviews and checks. Delegates to the
    # shared Reviews::BlockingMethodsComplete so a project whose review
    # gates have all completed re-validates exactly like the scan that
    # queued the escalation.
    def blocking_reviews_complete?(reviews, checks, pr_data)
      Reviews::BlockingMethodsComplete.call(
        project: @project,
        issue: @issue,
        reviews: reviews,
        checks: checks,
        pr_data: pr_data
      )
    end

    # Shared with the scan via PullRequests::DependenciesResolved so both
    # sides apply the same dependency gate.
    def dependencies_resolved?
      PullRequests::DependenciesResolved.call(
        collector: collector,
        project: @project,
        issue: @issue,
        logger: @logger
      )
    end
  end
end
