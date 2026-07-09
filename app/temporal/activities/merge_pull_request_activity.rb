# frozen_string_literal: true

module Activities
  # Merges a pull request using the project's configured merge method.
  # Idempotent: checks if the PR is already merged before attempting.
  # Updates the issue's pr_review_phase to "merged" on success.
  # Handles expected merge failures gracefully so the poll loop can
  # continue and re-scan later.
  #
  # Merge execution is routed through the repository provider
  # ({Automation::Providers::RepositoryProvider#merge_pull_request}) so
  # the activity is provider-agnostic — only the provider layer talks
  # to the source-control host.
  class MergePullRequestActivity < BaseActivity
    activity_name "MergePullRequest"

    PAID_AUTO_MERGED_LABEL = "paid-auto-merged"
    PAID_ESCALATED_LABEL = "paid-escalated"
    AUTO_MERGE_COMMENT = "This PR was automatically merged by paid's auto-merge feature."
    MERGE_PERMISSION_COMMENT_MARKER = "<!-- paid: merge-permission-rejection -->"

    def execute(input)
      project = Project.find(input[:project_id])
      pr_number = input[:pr_number]
      issue = Issue.find(input[:issue_id])

      unless project.auto_merge_enabled?
        logger.info(
          message: "pr_review.auto_merge_disabled",
          project_id: project.id,
          pr_number: pr_number
        )
        return { merged: false, skipped: true, pr_number: pr_number }
      end

      if issue.has_label?(Automation::Strategies::AutoMerge::SKIP_AUTO_MERGE_LABEL)
        logger.info(
          message: "pr_review.auto_merge_skipped_by_label",
          project_id: project.id,
          pr_number: pr_number,
          label: Automation::Strategies::AutoMerge::SKIP_AUTO_MERGE_LABEL
        )
        return { merged: false, skipped: true, pr_number: pr_number }
      end

      provider = Automation::Providers::Resolver.repository_for(project)
      repo = project.full_name

      # Scoped to the pre-merge fetch (which lazily resolves the GitHub
      # client): a missing/expired credential raises here, before
      # attempt_merge's own rescue is reached. Without this the activity
      # failed with no diagnostic trail. The rescue must NOT span the
      # post-merge block below, or a provider error after a successful merge
      # would report merged: false and re-scan an already-merged PR.
      pr_data = begin
        provider.fetch_pull_request(repo: repo, number: pr_number)
      rescue Automation::Providers::RepositoryProvider::ProviderError => e
        logger.warn(
          message: "pr_review.merge_provider_error",
          project_id: project.id,
          pr_number: pr_number,
          error: e.message
        )
        return { merged: false, error: e.message, pr_number: pr_number }
      end

      merged = if pr_data.merged
        logger.info(
          message: "pr_review.already_merged",
          project_id: project.id,
          pr_number: pr_number
        )
        true
      elsif !issue.merge_permission_retry_due?
        # A prior attempt hit a permanent GitHub App permission rejection
        # (e.g. missing `workflows` permission). Keep fetching the PR so we can
        # observe an out-of-band merge and clear the blocked state promptly, but
        # skip the expensive merge retry itself until the cooldown elapses.
        logger.info(
          message: "pr_review.merge_permission_cooldown",
          project_id: project.id,
          pr_number: pr_number
        )
        return { merged: false, skipped: true, pr_number: pr_number }
      else
        attempt_merge(provider, project, issue, repo, pr_number)
      end

      if merged
        had_escalated_label = issue.has_label?(PAID_ESCALATED_LABEL)
        # Clear any prior merge-permission rejection recorded on this issue —
        # otherwise the "Merge Blocked" indicator keeps showing on an already-
        # merged PR until the next full GitHub sync updates github_state.
        issue.update!(
          pr_review_phase: "merged",
          labels: issue.labels - [ PAID_ESCALATED_LABEL ],
          merge_permission_rejected_at: nil,
          merge_permission_rejection_reason: nil
        )
        IssueMergeSubscriptions::Deliver.call(issue: issue, event: :merged)
        # A merge resolves any prior escalation; strip the stale label so the
        # closed PR isn't left flagged as escalated.
        remove_escalated_label(provider, project, repo, pr_number) if had_escalated_label
        # Only label and comment on PRs that this activity actually merged —
        # already-merged PRs may have been merged manually by a human.
        unless pr_data.merged
          add_auto_merge_label(provider, project, repo, pr_number)
          add_merge_comment(provider, project, repo, pr_number)
        end
      end

      { merged: merged, pr_number: pr_number }
    end

    private

    def attempt_merge(provider, project, issue, repo, pr_number)
      config = Automation::Configuration::AutoMerge.from_project(project)

      result = provider.merge_pull_request(
        repo: repo,
        number: pr_number,
        method: config.merge_method.to_sym
      )
      logger.info(
        message: "pr_review.merged",
        project_id: project.id,
        pr_number: pr_number,
        merge_method: config.merge_method
      )
      result.merged
    rescue Automation::Providers::RepositoryProvider::ProviderError => e
      logger.warn(
        message: "pr_review.merge_failed_expected",
        project_id: project.id,
        pr_number: pr_number,
        error: e.message
      )
      handle_merge_failure(project, issue, repo, pr_number, config, e.message)
    end

    def handle_merge_failure(project, issue, repo, pr_number, config, message)
      return false unless permission_rejection?(message)

      fallback_merged = attempt_merge_with_pat_fallback(project, repo, pr_number, config)
      return true if fallback_merged == :merged
      return false if fallback_merged == :retryable_failure

      handle_merge_permission_rejection(
        project,
        issue,
        pr_number,
        message,
        fallback_attempted: fallback_merged == :permission_rejected
      )
      false
    end

    def permission_rejection?(message)
      AgentRun::PUSH_PERMISSION_REJECTION_KEYWORDS.any? { |keyword| message.to_s.include?(keyword) }
    end

    # Retries the merge with the project's PAT push-fallback credential when
    # the App installation token lacks a permission the merge needs (same
    # class of rejection the push retry already handles — see
    # Project#git_push_pat_fallback_configured?). Returns:
    # - :not_configured when fallback isn't configured
    # - :merged when the retry succeeds
    # - :permission_rejected when the fallback hit the same terminal rejection
    # - :retryable_failure for transient or non-permission fallback failures
    def attempt_merge_with_pat_fallback(project, repo, pr_number, config)
      client = project.git_push_fallback_client
      return :not_configured unless client

      fallback_provider = Automation::Providers::Github::RepositoryProvider.new(project, client: client)
      result = fallback_provider.merge_pull_request(
        repo: repo,
        number: pr_number,
        method: config.merge_method.to_sym
      )
      logger.info(
        message: "pr_review.merged_with_pat_fallback",
        project_id: project.id,
        pr_number: pr_number
      )
      result.merged ? :merged : :retryable_failure
    rescue Automation::Providers::RepositoryProvider::ProviderError => e
      logger.warn(
        message: "pr_review.merge_pat_fallback_failed",
        project_id: project.id,
        pr_number: pr_number,
        error: e.message
      )
      permission_rejection?(e.message) ? :permission_rejected : :retryable_failure
    end

    def handle_merge_permission_rejection(project, issue, pr_number, message, fallback_attempted:)
      issue.record_merge_permission_rejection!(reason: message)
      post_merge_permission_comment(project, issue, pr_number, fallback_attempted:)
    end

    def post_merge_permission_comment(project, issue, pr_number, fallback_attempted:)
      client = project.client
      return unless client

      return if merge_permission_comment_present?(client, project, pr_number)

      next_step = if fallback_attempted
        "**Next step:** the configured PAT push-fallback credential also could not merge this PR — " \
          "check that it has not expired or been revoked, then merge manually or wait for the next automatic check."
      else
        "**Next step:** grant the App the `workflows` permission, or configure a PAT push-fallback " \
          "credential for this project, then merge manually or wait for the next automatic check."
      end

      body = [
        MERGE_PERMISSION_COMMENT_MARKER,
        "**Auto-merge blocked: missing GitHub App permission**",
        "",
        "Paid could not merge this PR because the GitHub App installation token " \
          "lacks a permission needed for a change under `.github/workflows/` " \
          "(most commonly the `workflows` permission). This is permanent until " \
          "the App's permissions change, so Paid will keep checking periodically " \
          "rather than retrying every cycle.",
        "",
        next_step
      ].join("\n")

      client.add_comment(project.full_name, pr_number, body)
      logger.info(
        message: "github_integration.merge_permission_comment_posted",
        project_id: project.id,
        pr_number: pr_number
      )
    rescue GithubClient::Error => e
      logger.warn(
        message: "github_integration.merge_permission_comment_failed",
        project_id: project.id,
        pr_number: pr_number,
        error_class: e.class.name,
        error_message: e.message.to_s.truncate(200)
      )
    end

    def merge_permission_comment_present?(client, project, pr_number)
      comments = client.recent_issue_comments(project.full_name, pr_number)
      comments.any? { |comment| comment.respond_to?(:body) && comment.body&.include?(MERGE_PERMISSION_COMMENT_MARKER) }
    rescue GithubClient::Error => e
      logger.warn(
        message: "github_integration.merge_permission_comment_check_failed",
        project_id: project.id,
        pr_number: pr_number,
        error_class: e.class.name,
        error_message: e.message.to_s.truncate(200)
      )
      false
    end

    def add_auto_merge_label(provider, project, repo, pr_number)
      provider.add_labels(repo: repo, number: pr_number, labels: [ PAID_AUTO_MERGED_LABEL ])
    rescue Automation::Providers::RepositoryProvider::ProviderError => e
      logger.warn(
        message: "pr_review.add_label_failed",
        project_id: project.id,
        pr_number: pr_number,
        error: e.message
      )
    end

    def remove_escalated_label(provider, project, repo, pr_number)
      provider.remove_label(repo: repo, number: pr_number, label: PAID_ESCALATED_LABEL)
    rescue Automation::Providers::RepositoryProvider::ProviderError => e
      logger.warn(
        message: "pr_review.remove_escalated_label_failed",
        project_id: project.id,
        pr_number: pr_number,
        error: e.message
      )
    end

    def add_merge_comment(provider, project, repo, pr_number)
      provider.add_comment(repo: repo, number: pr_number, body: AUTO_MERGE_COMMENT)
    rescue Automation::Providers::RepositoryProvider::ProviderError => e
      logger.warn(
        message: "pr_review.add_comment_failed",
        project_id: project.id,
        pr_number: pr_number,
        error: e.message
      )
    end
  end
end
