# frozen_string_literal: true

# Entry point for assembling create_pr issue-implementation prompts through
# PromptAssembly. Pre-fetches shared data (issue comments), configures the
# ordered section providers, and delegates to {PromptAssembly::Build}.
#
# The assembled prompt preserves the content and ordering of the legacy
# {Prompts::BuildForIssue} path while adding full section provenance and
# keeping the task and safety-rules sections required (never suppressed).
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

    context = PromptAssembly::Context.new(
      issue: issue,
      project: project,
      github_client: github_client,
      agent_run: agent_run,
      issue_comments: fetched_comments
    )

    PromptAssembly::Build.call(sections: sections_for(context))
  end

  private

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
end
