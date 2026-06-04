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
    AUTO_MERGE_COMMENT = "This PR was automatically merged by paid's auto-merge feature."

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
      else
        attempt_merge(provider, project, repo, pr_number)
      end

      if merged
        issue.update!(pr_review_phase: "merged")
        IssueMergeSubscriptions::Deliver.call(issue: issue, event: :merged)
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

    def attempt_merge(provider, project, repo, pr_number)
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
