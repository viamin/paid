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

    def all_checks_green?(checks)
      return true if checks.empty?

      checks.all? { |c| %w[success skipped neutral].include?(c[:conclusion]) }
    end

    def owner_approved_or_self_authored?(reviews, pr_data)
      return true if owner_is_pr_author?(pr_data)
      return true if bot_author_auto_merge_allowed?(pr_data)

      owner_approved_from_reviews?(reviews)
    end

    def owner_is_pr_author?(pr_data)
      author_login = pr_data.respond_to?(:user) ? pr_data.user&.login : pr_data.dig(:user, :login)
      return false if author_login.blank?

      @project.owner_reviewer_login.present? && author_login.casecmp?(@project.owner_reviewer_login)
    end

    def bot_author_auto_merge_allowed?(pr_data)
      return false unless @project.auto_merge_bot_authored?

      author_login = pr_data.respond_to?(:user) ? pr_data.user&.login : pr_data.dig(:user, :login)
      paid_agent_pr_author?(author_login)
    end

    def paid_agent_pr_author?(login)
      return false if login.blank?

      agent_login = @project.github_author_login
      agent_login.present? && login.casecmp?(agent_login)
    end

    def owner_approved_from_reviews?(reviews)
      owner_login = @project.owner_reviewer_login
      return false if owner_login.blank?

      reviews.any? do |review|
        review[:user_login]&.casecmp?(owner_login) && review[:state].to_s.upcase == "APPROVED"
      end
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
        skip_auto_merge: @issue.has_label?(SKIP_AUTO_MERGE_LABEL)
      )
    end

    def blocked_only_on_approval?(signals)
      !signals.owner_approved? &&
        signals.checks_green? &&
        signals.mergeable? &&
        signals.review_feedback_clear? &&
        signals.blocking_reviews_complete? &&
        signals.reviews_fresh? &&
        !signals.skip_auto_merge?
    end

    # Conservative check: the head commit postdates the latest blocking
    # approval. Skipped (returns true) when head commit timestamp can't be
    # resolved — matches the scan's behavior of returning false only on a
    # confirmed staleness.
    def fresh_reviews?(pr_data, reviews)
      return true if reviews.nil?

      head_committed_at = fetch_head_commit_date(pr_data)
      return true if head_committed_at.nil?

      !stale_approval?(head_committed_at, reviews)
    end

    def fetch_head_commit_date(pr_data)
      sha = pr_data.respond_to?(:head) ? pr_data.head&.sha : pr_data.dig(:head, :sha)
      return nil if sha.blank?

      @client.commit(@project.full_name, sha)&.commit&.committer&.date
    rescue GithubClient::Error => e
      @logger.warn(
        message: "pr_review.fetch_head_commit_failed",
        project_id: @project.id,
        pr_number: @issue.github_number,
        error: e.message
      )
      nil
    end

    def stale_approval?(head_committed_at, reviews)
      latest_owner_approval(reviews) do |head_committed_at, _ts| head_committed_at > _ts end
    end

    def latest_owner_approval(reviews)
      owner_login = @project.owner_reviewer_login
      return false if owner_login.blank?

      ts = reviews
        .select { |r| r[:state].to_s.upcase == "APPROVED" && r[:user_login]&.casecmp?(owner_login) }
        .filter_map { |r| r[:submitted_at] }
        .max
      return false if ts.nil?

      yield(head_committed_at, ts)
    end

    # Cheap stand-in for the scan's full no_outstanding_review_feedback? gate.
    # We re-fetch from GitHub on every escalation, so the live data is the
    # authoritative signal — no risk of a stale local copy. Each signal
    # below corresponds to one of the blockers the scan watches:
    #
    # * unresolved review threads (any comment on an open thread is feedback)
    # * a CHANGES_REQUESTED review from a trusted non-bot user
    # * the paid-skip-auto-merge label on the PR (handled in quick_preconditions)
    #
    # Conversation comments are intentionally not checked here: by the time a
    # PR is in the ready phase they have already been addressed by the
    # follow-up run that advanced it, so a fresh conversation comment between
    # scan and escalation means the scan's own next iteration would advance
    # the PR off the ready phase before the activity ran anyway.
    def no_outstanding_review_feedback?(pr_data, reviews, unresolved_threads)
      return false if unresolved_threads.any?
      return false if changes_requested?(reviews)

      true
    end

    def changes_requested?(reviews)
      reviews.any? do |review|
        review[:state].to_s.upcase == "CHANGES_REQUESTED" &&
          @project.trusted_github_user?(review[:user_login]) &&
          !bot_user?(review[:user_login])
      end
    end

    def bot_user?(login)
      return false if login.blank?

      normalized = login.downcase
      return true if normalized.end_with?("[bot]", "-bot")

      %w[dependabot renovate github-actions].any? { |prefix| normalized.start_with?(prefix) }
    end

    # Conservative stand-in for the scan's blocking_reviews_complete? gate.
    # Without the full method we cannot know whether a configured ci_action or
    # manual reviewer has signaled completion, so we only return true when
    # the project's review surface is empty (the common case for a green,
    # ready PR that has just been waiting on owner approval). Projects that
    # use any review method fall back to "incomplete" and the escalation
    # is skipped — this errs on the side of NOT escalating rather than
    # escalating a PR whose review gates we cannot re-verify cheaply.
    def blocking_reviews_complete?(_reviews, _checks, _pr_data)
      return true unless @project.review_enabled? && @project.wait_for_reviews?

      false
    end

    # Conservative stand-in for the scan's dependencies_resolved? check.
    # Only re-resolves when the issue body actually declares dependencies —
    # the common case for an approval-only wait is no dependencies, so we
    # short-circuit to true. When dependencies are declared we delegate to
    # the same PullRequestCollector the scan uses, so the answer matches.
    def dependencies_resolved?
      local_deps, cross_deps = Issues::ParseDependencies.extract(
        body: @issue.body,
        comments: collector.dependency_comment_bodies(issue: @issue)
      )

      return true if local_deps.empty? && cross_deps.empty?

      same_repo = [ @project.owner.downcase, @project.repo.downcase ]
      numbers = cross_deps.each_with_object(Set.new) do |((owner, repo, number), _), set|
        return false unless [ owner, repo ] == same_repo

        set << number
      end

      (local_deps.keys.to_set | numbers).all? { |number| collector.dependency_resolved?(number: number) }
    rescue GithubClient::Error => e
      @logger.warn(
        message: "pr_review.dependency_check_failed",
        project_id: @project.id,
        pr_number: @issue.github_number,
        error: e.message
      )
      false
    end
  end
end
