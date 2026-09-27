# frozen_string_literal: true

# Entry point for assembling create_pr issue-implementation prompts through
# PromptAssembly. Pre-fetches shared data (issue comments), configures the
# ordered section providers, and delegates to {PromptAssembly::Build}.
#
# The assembled prompt preserves the content and ordering of the legacy
# {Prompts::BuildForIssue} path while adding full section provenance and
# keeping the task and safety-rules sections required (never suppressed).
#
# @spec PROMPT-ASSEMBLY-014
#
# @example
#   result = PromptAssembly::BuildIssuePrompt.call(
#     issue: issue, project: project, github_client: client, agent_run: run
#   )
#   result.text        # => "# Task\n\nYou are working on..."
#   result.provenance  # => { digest: "...", sections: [...], ... }
class PromptAssembly::BuildIssuePrompt
  UntrustedIssueError = Prompts::BuildForIssue::UntrustedIssueError

  def self.call(...)
    new(...).call
  end

  attr_reader :issue, :project, :github_client, :agent_run

  def initialize(issue:, project:, github_client: nil, agent_run: nil)
    @issue = issue
    @project = project
    @github_client = github_client
    @agent_run = agent_run
  end

  def call
    raise UntrustedIssueError,
      "Cannot build prompt for issue from untrusted user: #{issue.github_creator_login}" unless issue.trusted?

    refresh_code_scanning_context

    context = PromptAssembly::Context.new(
      issue: issue,
      project: project,
      github_client: github_client,
      agent_run: agent_run,
      issue_comments: fetched_comments
    )

    PromptAssembly::Build.call(
      sections: sections_for(context),
      profile: resolved_profile
    )
  end

  private

  def resolved_profile
    PromptAssembly::ProfileResolution.resolve(
      project: project,
      account: project&.account,
      goal: agent_run&.goal || "create_pr"
    )
  end

  def sections_for(context)
    [
      PromptAssembly::Sections::IssueTask.call(context),
      PromptAssembly::Sections::TrustedComments.call(context),
      PromptAssembly::Sections::ClarifiedRequirements.call(context),
      PromptAssembly::Sections::ServiceEnvironment.call(context),
      PromptAssembly::Sections::KnowledgeContext.call(context),
      PromptAssembly::Sections::StyleGuides.call(context),
      PromptAssembly::Sections::ProjectConventions.call(context),
      PromptAssembly::Sections::LidWorkflow.call(context),
      PromptAssembly::Sections::MarketplaceAttachments.call(context),
      PromptAssembly::Sections::RdrRolloutGuard.call(context),
      PromptAssembly::Sections::SafetyRules.call(context)
    ]
  end

  # Fetched once and shared by TrustedComments and ClarifiedRequirements so
  # the comment thread is downloaded a single time per prompt build.
  def fetched_comments
    @fetched_comments ||= begin
      return [] unless github_client

      github_client.issue_comments(project.full_name, issue.github_number)
    rescue GithubClient::Error
      []
    end
  end

  # A poll snapshot can be old by the time a queued run starts. Refreshing the
  # synthetic issue here ensures the final prompt is built from the current
  # target-branch finding rather than relying on a private GitHub alert URL.
  # @spec GITHUB-SYNC-015
  def refresh_code_scanning_context
    return unless github_client && issue.source == Issue::SYNTHETIC_CODE_SCANNING_SOURCE

    alert_number = issue.github_issue_id - Issue::SYNTHETIC_CODE_SCANNING_ID_OFFSET
    alert = github_client.code_scanning_alert(project.full_name, alert_number, default_branch: project.default_branch)
    if alert
      SecurityAlerts::ProcessCodeScanningAlerts.new(project)
        .call([ alert ], excluding_run_id: agent_run&.id)
    end
    issue.reload
  rescue GithubClient::Error => e
    Rails.logger.warn(
      message: "github_sync.code_scanning_prompt_refresh_failed",
      project_id: project.id,
      alert_number: alert_number,
      error: e.message
    )
  end
end
