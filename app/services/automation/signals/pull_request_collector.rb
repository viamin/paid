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
                line: comment.line
              }
            end
          }
        end
      rescue Automation::Providers::ReviewProvider::ProviderError => e
        log_signal_error("review_threads", issue, e)
        nil
      end

      def dependency_comment_bodies(issue:)
        providers.work_item_provider.fetch_issue_comments(
          repo: providers.repo,
          number: issue.github_number
        ).filter_map(&:body)
      rescue Automation::Providers::WorkItemProvider::ProviderError => e
        log_signal_error("dependencies_resolved", issue, e)
        []
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
      rescue GithubClient::Error => e
        log_signal_error("fetch_head_commit", issue, e)
        nil
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
    end
  end
end
