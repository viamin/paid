# frozen_string_literal: true

module Automation
  module Signals
    # Collects provider-neutral PR signals for the scan activity.
    #
    # The collector is Layer 2 of the automation modularization
    # (RDR-023): it hides provider I/O behind the {Automation::Providers}
    # adapters so the activity shrinks to orchestration glue. Every
    # adapter shares the single client the orchestration layer resolved
    # (forwarded through {ProviderContext}), and provider failures are
    # translated into best-effort empty results with a structured warning
    # rather than aborting the whole scan.
    #
    # Two signals stay client-backed rather than adapter-backed:
    #
    # * CI check runs — transient-failure detection consumes the
    #   client-computed +output_text+ and the raw GitHub status/conclusion
    #   strings, which the minimal {Data::CheckRun} contract intentionally
    #   does not carry. Routing them through the narrow data class would
    #   silently drop that detail.
    # * Review comments / changed-files comparison — the stale-review
    #   guard matches GitHub's raw +pull_request_review_id+ and diff file
    #   paths, which no provider-neutral data class models yet.
    # * Dependency resolution — distinguishing "PR/issue not found" from
    #   other provider failures drives the PR-vs-issue fallback, and the
    #   provider error hierarchy does not yet expose a NotFound subclass.
    #
    # Both remain GitHub-specific until a second provider lands, matching
    # the RDR's "generalize only when a second provider is added" guidance.
    class PullRequestCollector
      attr_reader :providers, :client, :logger

      def initialize(providers:, client:, logger:)
        @providers = providers
        @client = client
        @logger = logger
      end

      def fetch_pull_request(issue:)
        pr_data = providers.repository_provider.fetch_pull_request(
          repo: providers.repo,
          number: issue.github_number
        )

        PullRequestSnapshot.from_provider(pr_data)
      rescue Automation::Providers::RepositoryProvider::ProviderError => e
        log_signal_error("fetch_pr", issue, e)
        nil
      end

      # Returns the raw check-run hashes the scanner already consumes
      # (preserving +output_text+, +job_id+ and the raw status/conclusion
      # strings the transient-failure detector relies on). See the class
      # docs for why this signal stays client-backed.
      def fetch_check_runs(pr_data:)
        return [] unless pr_data

        client.check_runs_for_ref(providers.repo, pr_data.head.sha)
      rescue GithubClient::AuthenticationError
        raise
      rescue GithubClient::Error => e
        logger.warn(
          message: "pr_scanner.ci_check_failed",
          project_id: providers.project.id,
          pr_number: pr_data.number,
          error: e.message
        )
        nil
      end

      def fetch_reviews(issue:)
        providers.review_provider.fetch_reviews(
          repo: providers.repo,
          pr_number: issue.github_number
        ).map do |review|
          {
            id: review.id,
            user_login: review.author_login,
            state: review.raw_state.presence || review.state.to_s.upcase,
            body: review.body,
            submitted_at: review.submitted_at,
            commit_id: review.commit_sha
          }
        end
      rescue Automation::Providers::ReviewProvider::ProviderError => e
        log_signal_error("fetch_reviews", issue, e)
        nil
      end

      def fetch_unresolved_threads(issue:)
        providers.review_provider.fetch_review_threads(
          repo: providers.repo,
          pr_number: issue.github_number
        ).reject(&:resolved).map do |thread|
          {
            id: thread.id,
            is_resolved: thread.resolved,
            comments: thread.comments.map do |comment|
              {
                author: comment.author_login,
                body: comment.body,
                path: comment.path,
                line: comment.line,
                created_at: comment.created_at,
                commit_id: comment.commit_id
              }
            end
          }
        end
      rescue Automation::Providers::ReviewProvider::ProviderError => e
        log_signal_error("review_threads", issue, e)
        nil
      end

      def fetch_issue_comments(issue:)
        providers.work_item_provider.fetch_issue_comments(
          repo: providers.repo,
          number: issue.github_number
        )
      rescue Automation::Providers::WorkItemProvider::ProviderError => e
        log_signal_error("issue_comments", issue, e)
        []
      end

      # Fetches conversation comments using the scanner's historical
      # "recent comments, then paginate if the cutoff window might extend
      # beyond the first page" behavior.
      def fetch_recent_issue_comments(issue:, cutoff: nil)
        comments = client.recent_issue_comments(providers.repo, issue.github_number)

        if cutoff && comments.multi_page? && comments.any? &&
            comments.all? { |comment| comment_created_at(comment).nil? || comment_created_at(comment) > cutoff }
          client.issue_comments(providers.repo, issue.github_number)
        else
          comments
        end
      rescue GithubClient::AuthenticationError
        raise
      rescue GithubClient::Error => e
        log_signal_error("recent_issue_comments", issue, e)
        []
      end

      # Returns the raw review-comment hashes the stale-review guard
      # already consumes, preserving +pull_request_review_id+ and +path+.
      def fetch_review_comments(issue:)
        client.pull_request_review_comments(providers.repo, issue.github_number)
      rescue GithubClient::AuthenticationError
        raise
      rescue GithubClient::Error => e
        log_signal_error("review_comments", issue, e)
        nil
      end

      def dependency_comment_bodies(issue:)
        fetch_issue_comments(issue:).filter_map(&:body)
      end

      # A "Depends on #N" ref can point to either a PR or an issue. Treat
      # the dep as satisfied when #N is a merged PR OR a closed issue —
      # both mean the upstream work is done. Without the issue fallback,
      # depending on a tracking issue would silently block auto-merge
      # forever because the pull_request endpoint 404s for issue numbers.
      def dependency_resolved?(number:)
        pr_data = begin
          client.pull_request(providers.repo, number)
        rescue GithubClient::NotFoundError
          nil
        end

        return pull_request_merged?(pr_data) if pr_data

        issue_data = client.issue(providers.repo, number)
        dependency_value(issue_data, :state) == "closed"
      rescue GithubClient::NotFoundError
        false
      end

      # Returns the HEAD commit's committer timestamp, used by stale-review
      # detection and progress tracking. Stays client-backed because the
      # raw commit payload (commit.committer.date) is GitHub-specific and
      # no provider interface models commit metadata yet.
      def fetch_head_commit_date(issue:, pr_data:)
        sha = pr_data&.head&.sha
        return nil if sha.nil?

        client.commit(providers.repo, sha)&.commit&.committer&.date
      rescue GithubClient::AuthenticationError
        raise
      rescue GithubClient::Error => e
        log_signal_error("fetch_head_commit", issue, e)
        nil
      end

      # Walks this many commits along the first-parent chain before failing
      # closed. Matches GitHub's compare response cap so the walk cannot
      # enumerate more commits than the upstream endpoint can return.
      FIRST_PARENT_WALK_LIMIT = 250

      # Returns true when every commit on the first-parent path between
      # +approval_sha+ and +head_sha+ (inclusive of head, exclusive of
      # approval) is a clean merge of +base_branch+ into the feature
      # branch — i.e. no author-side content changed since the approval.
      # See AUTO-MERGE-006: a clean merge carries an identical tree to
      # its first parent and merges a side that is reachable from the
      # base branch tip, so no new code reached the PR head.
      #
      # The first-parent walk is used (rather than iterating
      # +compare.commits+) because the compare endpoint is equivalent to
      # +git log BASE..HEAD+ and therefore also returns the base-branch
      # commits that arrived only through the merge's second parent
      # (the typical `chore: merge origin/main` case). Those single-
      # parent commits are content-free by transitivity — once a merge's
      # second parent is reachable from the base branch tip, every
      # descendant of that second parent is also reachable — so the walk
      # only validates the commits on the feature branch's natural
      # history and ignores the rest.
      #
      # Fails closed (returns false) on a single-parent commit on the
      # first-parent chain (author-side feature-branch content), on a
      # merge whose tree differs from its first parent (conflict
      # resolution or author-side change), on a merge whose second
      # parent is not reachable from the base branch tip, on a force-
      # push or history rewrite that dropped the approved commit from
      # HEAD's lineage (compare status is not +ahead+/+identical+), on
      # an octopus merge or root commit, on an unresolvable parent
      # lookup, or when the first-parent walk exceeds the response cap
      # (the range cannot be positively classified). Every classification
      # outcome is logged so a stall is diagnosable.
      def only_base_merge_commits_since?(approval_sha:, head_sha:, base_branch:, issue: nil)
        return false if approval_sha.blank? || head_sha.blank? || base_branch.blank?
        return true if approval_sha == head_sha

        base_tip_sha = base_branch_tip_sha(base_branch)
        if base_tip_sha.blank?
          log_signal_error(
            "clean_base_merge_range",
            issue,
            GithubClient::Error.new("base branch tip unresolved: #{base_branch}")
          ) if issue
          return false
        end

        # A quick ancestry check rejects force-pushes and history
        # rewrites that dropped the approved commit from HEAD's
        # lineage. Without it the walk would exhaust the
        # +FIRST_PARENT_WALK_LIMIT+ before discovering the approval is
        # unreachable.
        ancestry = client.compare(providers.repo, approval_sha, head_sha)
        return false unless %w[ahead identical].include?(ancestry&.status.to_s)

        walk = walk_first_parent_chain(
          head_sha: head_sha,
          approval_sha: approval_sha,
          base_tip_sha: base_tip_sha
        )

        case walk[:outcome]
        when :clean
          log_classification(issue, approval_sha:, head_sha:, first_parent_steps: walk[:steps])
          true
        when :stale
          log_stale_classification(
            issue,
            approval_sha:,
            head_sha:,
            first_parent_steps: walk[:steps],
            reason: walk[:reason]
          )
          false
        when :walk_exceeded
          log_truncated_range(
            issue,
            approval_sha:,
            head_sha:,
            first_parent_steps: walk[:steps]
          )
          false
        end
      rescue GithubClient::AuthenticationError
        raise
      rescue GithubClient::Error, StandardError => e
        log_signal_error("clean_base_merge_range", issue, e) if issue
        false
      end

      # Returns true when the diff between the review's commit and the PR
      # HEAD touches a file named in the review's inline comments.
      def review_diff_touches_reviewed_files?(issue:, review:, pr_data: nil)
        review_id = review[:id]
        reviewed_commit = review[:commit_id]
        return true if review_id.nil? || reviewed_commit.nil?

        review_comments = fetch_review_comments(issue:)
        return true if review_comments.nil?

        reviewed_paths = review_comments
          .select { |comment| comment[:pull_request_review_id] == review_id }
          .filter_map { |comment| comment[:path] }
          .to_set
        return false if reviewed_paths.empty?

        head_sha = pr_data&.head&.sha || fetch_pull_request(issue:)&.head&.sha
        return true if head_sha.nil?
        return false if head_sha == reviewed_commit

        changed_files = client.compare_changed_files(
          providers.repo, reviewed_commit, head_sha
        )
        changed_files.any? { |path| reviewed_paths.include?(path) }
      rescue GithubClient::AuthenticationError
        raise
      rescue GithubClient::Error => e
        log_signal_error("review_diff_check", issue, e)
        true
      end

      def remove_label(issue:, label:)
        providers.repository_provider.remove_label(
          repo: providers.repo,
          number: issue.github_number,
          label: label
        )
      rescue Automation::Providers::RepositoryProvider::ProviderError => e
        logger.warn(
          message: "pr_scanner.remove_escalated_label_failed",
          project_id: providers.project.id,
          pr_number: issue.github_number,
          error: e.message
        )
      end

      private

      def pull_request_merged?(pr_data)
        dependency_value(pr_data, :merged) == true || dependency_value(pr_data, :merged_at).present?
      end

      # Walks the first-parent chain from +head_sha+ back to
      # +approval_sha+. Each commit on the chain must be a clean merge
      # of base (two-parent merge whose tree matches its first parent's
      # tree and whose second parent is reachable from +base_tip_sha+).
      # A single-parent commit on the chain is author-side feature
      # branch content and stops the walk with +:stale+. The walk is
      # bounded at +FIRST_PARENT_WALK_LIMIT+ commits; exceeding the
      # bound returns +:walk_exceeded+ so the caller can fail closed.
      #
      # Returns a hash describing the outcome so the caller can log it:
      # +{outcome: :clean|:stale|:walk_exceeded, steps:, reason:}+.
      # +reason+ is set only when +outcome: :stale+.
      def walk_first_parent_chain(head_sha:, approval_sha:, base_tip_sha:)
        current_sha = head_sha
        current_commit = nil
        steps = 0

        while current_sha != approval_sha
          return { outcome: :walk_exceeded, steps: steps } if steps >= FIRST_PARENT_WALK_LIMIT

          # Reuse the prior iteration's first-parent commit when possible:
          # the SHA reassignment below means the next loop's first fetch
          # would otherwise re-request the commit we just resolved,
          # costing an extra GitHub call per step in the chain.
          commit = current_commit || client.commit(providers.repo, current_sha)
          return { outcome: :stale, steps: steps, reason: :commit_unresolved } unless commit

          parents = Array(commit.parents)
          parent_shas = parents.map { |p| p.sha.to_s }

          case parent_shas.size
          when 1
            return { outcome: :stale, steps: steps, reason: :single_parent_commit }
          when 2
            first_parent_sha, second_parent_sha = parent_shas

            first_parent_commit = client.commit(providers.repo, first_parent_sha)
            return { outcome: :stale, steps: steps, reason: :first_parent_unresolved } unless first_parent_commit

            merge_tree = commit.commit&.tree&.sha.to_s
            first_parent_tree = first_parent_commit.commit&.tree&.sha.to_s
            if merge_tree.empty? || merge_tree != first_parent_tree
              return { outcome: :stale, steps: steps, reason: :tree_differs_from_first_parent }
            end

            unless ancestor_of_base?(second_parent_sha, base_tip_sha)
              return { outcome: :stale, steps: steps, reason: :second_parent_not_from_base }
            end

            current_sha = first_parent_sha
            current_commit = first_parent_commit
            steps += 1
          else
            # Octopus merge or root commit: neither belongs on the
            # first-parent chain of a normal PR feature branch.
            return { outcome: :stale, steps: steps, reason: :octopus_or_root }
          end
        end

        { outcome: :clean, steps: steps }
      end

      def base_branch_tip_sha(base_branch)
        ref = client.ref(providers.repo, "heads/#{base_branch}")
        ref&.object&.sha.to_s.presence
      rescue GithubClient::AuthenticationError
        raise
      rescue GithubClient::Error, StandardError
        nil
      end

      # True when +ancestor_sha+ is reachable from +descendant_sha+ (i.e.
      # the descendant's history contains the ancestor, including the
      # identity case where they are the same commit). Uses the compare API
      # rather than a parent walk so deep histories do not blow up the
      # number of GitHub calls per staleness check.
      def ancestor_of_base?(ancestor_sha, descendant_sha)
        return true if ancestor_sha == descendant_sha

        comparison = client.compare(providers.repo, ancestor_sha, descendant_sha)
        %w[ahead identical].include?(comparison&.status.to_s)
      end

      def log_classification(issue, approval_sha:, head_sha:, first_parent_steps:)
        return unless issue

        logger.info(
          message: "pr_scanner.review_freshness_range_classified",
          project_id: providers.project.id,
          pr_number: issue.github_number,
          approval_sha: approval_sha,
          head_sha: head_sha,
          first_parent_steps: first_parent_steps
        )
      end

      def log_stale_classification(issue, approval_sha:, head_sha:, first_parent_steps:, reason:)
        return unless issue

        logger.warn(
          message: "pr_scanner.review_freshness_range_stale",
          project_id: providers.project.id,
          pr_number: issue.github_number,
          approval_sha: approval_sha,
          head_sha: head_sha,
          first_parent_steps: first_parent_steps,
          reason: reason.to_s
        )
      end

      # Walks that exceed +FIRST_PARENT_WALK_LIMIT+ fail closed; the
      # warn makes the resulting stall diagnosable as a deliberate
      # freshness decision rather than a missed bug.
      def log_truncated_range(issue, approval_sha:, head_sha:, first_parent_steps:)
        return unless issue

        logger.warn(
          message: "pr_scanner.review_freshness_range_truncated",
          project_id: providers.project.id,
          pr_number: issue.github_number,
          approval_sha: approval_sha,
          head_sha: head_sha,
          first_parent_steps: first_parent_steps,
          walk_limit: FIRST_PARENT_WALK_LIMIT
        )
      end

      # Accepts Sawyer::Resource objects (method access), Hashes with
      # symbol or string keys, or any +#[]+ object so the same lookup
      # works against raw GitHub responses and test doubles alike.
      def dependency_value(source, key)
        return nil if source.nil?

        if source.respond_to?(key)
          source.public_send(key)
        elsif source.respond_to?(:key?) && source.key?(key)
          source[key]
        elsif source.respond_to?(:[])
          source[key.to_s]
        end
      end

      def log_signal_error(signal, issue, error)
        logger.warn(
          message: "pr_scanner.signal_check_failed",
          signal: signal,
          project_id: providers.project.id,
          pr_number: issue.github_number,
          error: error.message
        )
      end

      def comment_created_at(comment)
        if comment.respond_to?(:created_at)
          comment.created_at
        elsif comment.respond_to?(:[])
          comment[:created_at] || comment["created_at"]
        end
      end
    end
  end
end
